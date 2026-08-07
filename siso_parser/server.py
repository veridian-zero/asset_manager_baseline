import json
import os
import csv
import re
import io
import zipfile
import uuid
import asyncio
import random
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse, FileResponse
from sse_starlette.sse import EventSourceResponse
from rapidfuzz import fuzz

app = FastAPI(title="Local Asset Manager & SISO API")

DB_PATH = os.getenv("DB_PATH", "./siso_db.json")
MODELS_ROOT = os.getenv("MODELS_ROOT", "./Gladiator_Real_Data")

siso_db = []
export_cache = {}

@app.on_event("startup")
def load_db():
    global siso_db
    if os.path.exists(DB_PATH):
        with open(DB_PATH, 'r', encoding='utf-8') as f:
            siso_db = json.load(f)
        print(f"Loaded {len(siso_db)} SISO entries into memory.")
    else:
        print(f"Warning: DB_PATH '{DB_PATH}' not found!")

@app.get("/", response_class=HTMLResponse)
def serve_gui():
    if os.path.exists("index.html"):
        with open("index.html", "r", encoding="utf-8") as f:
            return f.read()
    return "<h1>Local Asset Manager Running</h1><p>index.html not found.</p>"

@app.get("/media/{image_name}")
def get_media_image(image_name: str):
    models_path = Path(MODELS_ROOT)
    if not models_path.exists():
        raise HTTPException(status_code=404, detail="Models root not found.")

    for thumb_file in models_path.rglob(image_name):
        if thumb_file.is_file():
            return FileResponse(path=thumb_file, media_type="image/png")

    raise HTTPException(status_code=404, detail=f"Image {image_name} not found in model thumbnails.")

@app.get("/api/catalog")
def get_catalog():
    catalog_items = []
    models_path = Path(MODELS_ROOT)
    
    if not models_path.exists():
        return []

    for sidecar_file in sorted(models_path.rglob(".*.metadata.json")):
        try:
            with open(sidecar_file, 'r', encoding='utf-8-sig') as f:
                data = json.load(f)
                
            inspector = data.get("inspector", {})
            siso = data.get("siso", {})
            model_name = data.get("modelName", sidecar_file.name.replace(".metadata.json", "").lstrip("."))

            try:
                rel_location = f"./{sidecar_file.parent.relative_to(models_path)}".replace("\\", "/")
            except ValueError:
                rel_location = str(sidecar_file.parent).replace("\\", "/")

            thumb_dir = sidecar_file.parent / f".{model_name}_thumbs"
            thumbs_str = ""
            if thumb_dir.exists():
                thumbs = [t.name for t in sorted(thumb_dir.glob("*.png"))]
                thumbs_str = "|".join(thumbs)

            item = {
                "AssetID": data.get("assetId", ""),
                "Name": model_name,
                "Status": data.get("status", "Active"),
                "ExclusionReason": data.get("exclusionReason", ""),
                "Description": data.get("description", "OpenFlight 3D visual asset."),
                "AssetLocation": rel_location,
                "Format": "OpenFlight (*.FLT)",
                "StorageSize": str(data.get("storageSizeKB", 0)),
                "Enumeration": siso.get("enumeration", ""),
                "Domain": siso.get("domain", ""),
                "CountryOfOrigin": siso.get("countryOfOrigin", ""),
                "Type": siso.get("kind", "Platform"),
                "SubType": siso.get("subType", ""),
                "LODs": inspector.get("lods", ""),
                "Articulations": inspector.get("articulations", ""),
                "DamageStates": inspector.get("damageStates", ""),
                "AppearanceStates": inspector.get("appearanceStates", ""),
                "PackageList": inspector.get("packageList", ""),
                "Parameterisation": inspector.get("boundingBox", ""),
                "TextureResolution": inspector.get("textureResolution", ""),
                "TextureWarnings": inspector.get("textureWarnings", ""),
                "Thumbnails": thumbs_str,
                "ThumbnailCaptions": "Front|Rear|Left Side|Right Side|Top"
            }
            catalog_items.append(item)
        except Exception as e:
            print(f"[CATALOG ERROR] Error reading sidecar {sidecar_file}: {e}")

    return catalog_items

@app.get("/api/export-stream")
async def export_stream(
    sample: str = "false",
    sample_size: int = 10,
    domain: str = "ALL"
):
    """Streams real-time SSE progress during ZIP generation using FastAPI native StreamingResponse."""
    async def event_generator():
        models_path = Path(MODELS_ROOT)
        if not models_path.exists():
            yield f"data: {json.dumps({'status': 'error', 'message': 'Models root directory not found.'})}\n\n"
            return

        is_sample = str(sample).lower() in ["true", "1", "yes"]
        target_sample_size = max(1, int(sample_size))

        sidecars = sorted(list(models_path.rglob(".*.metadata.json")))
        
        # --- FILTER PASS ---
        filtered_sidecars = []
        for sidecar_file in sidecars:
            try:
                with open(sidecar_file, 'r', encoding='utf-8-sig') as f:
                    data = json.load(f)
                
                if data.get("status", "Active").lower() == "excluded":
                    continue
                
                siso = data.get("siso", {})
                item_domain = siso.get("domain", "")
                
                if domain != "ALL" and item_domain.lower() != domain.lower():
                    continue

                filtered_sidecars.append((sidecar_file, data))
            except Exception as e:
                print(f"[EXPORT FILTER WARNING] Skipping unreadable file {sidecar_file.name}: {e}")
                continue

        # --- RANDOM SAMPLING PASS ---
        if is_sample and len(filtered_sidecars) > 0:
            count_to_take = min(len(filtered_sidecars), target_sample_size)
            filtered_sidecars = random.sample(filtered_sidecars, count_to_take)

        total_items = len(filtered_sidecars)

        yield f"data: {json.dumps({'stage': 1, 'stageName': 'Scanning Sidecars & Compiling CSV', 'progress': 5, 'log': f'Filtered catalog down to {total_items} asset(s) for export.', 'totalItems': total_items, 'processedItems': 0})}\n\n"

        output_rows = []
        used_thumbnails = set()
        
        fieldnames = [
            "Name", "Description", "Thumbnails", "ThumbnailCaptions", "AssetID", 
            "AppearanceStates", "Articulations", "AssetLocation", "BehaviouralData", 
            "Classification", "CountryOfOrigin", "CrewSpaces", "Custodian", 
            "DamageStates", "DateBuilt", "Domain", "DomainDevelopedFor", 
            "DownloadLink", "Enumeration", "Format", "Internals", "LODs", 
            "MultiSpectral", "PackageList", "Parameterisation", "Reference", 
            "Relationships", "StorageSize", "SubType", "TextureResolution", 
            "Type", "UsageRightsLimitations", "VVDocs", "WhereUsed"
        ]

        for idx, (sidecar_file, data) in enumerate(filtered_sidecars, 1):
            try:
                model_name = data.get("modelName", sidecar_file.name.replace(".metadata.json", "").lstrip("."))
                inspector = data.get("inspector", {})
                siso = data.get("siso", {})

                thumb_dir = sidecar_file.parent / f".{model_name}_thumbs"
                thumbs = []
                if thumb_dir.exists():
                    for t_file in sorted(thumb_dir.glob("*.png")):
                        thumbs.append(t_file.name)
                        used_thumbnails.add(t_file)

                try:
                    rel_loc = f"./{sidecar_file.parent.relative_to(models_path)}".replace("\\", "/")
                except ValueError:
                    rel_loc = str(sidecar_file.parent).replace("\\", "/")

                size_kb = str(data.get("storageSizeKB", 0))

                row = {
                    "Name": model_name,
                    "Description": data.get("description", "OpenFlight 3D visual asset."),
                    "Thumbnails": "|".join(thumbs),
                    "ThumbnailCaptions": "Front|Rear|Left Side|Right Side|Top",
                    "AssetID": data.get("assetId", ""),
                    "AppearanceStates": inspector.get("appearanceStates", ""),
                    "Articulations": inspector.get("articulations", ""),
                    "AssetLocation": rel_loc,
                    "BehaviouralData": "No",
                    "Classification": "UK OFFICIAL",
                    "CountryOfOrigin": siso.get("countryOfOrigin", ""),
                    "CrewSpaces": "Unknown",
                    "Custodian": "Defence Modelling and Simulation Centre",
                    "DamageStates": inspector.get("damageStates", ""),
                    "DateBuilt": "",
                    "Domain": siso.get("domain", ""),
                    "DomainDevelopedFor": "",
                    "DownloadLink": "",
                    "Enumeration": siso.get("enumeration", ""),
                    "Format": "OpenFlight (*.FLT)",
                    "Internals": "Unknown",
                    "LODs": inspector.get("lods", ""),
                    "MultiSpectral": "Unknown",
                    "PackageList": inspector.get("packageList", ""),
                    "Parameterisation": inspector.get("boundingBox", "Unknown"),
                    "Reference": "",
                    "Relationships": "",
                    "StorageSize": size_kb,
                    "SubType": siso.get("subType", ""),
                    "TextureResolution": inspector.get("textureResolution", ""),
                    "Type": siso.get("kind", "Platform"),
                    "UsageRightsLimitations": "Yes\nMOD use including Industry working on MOD Projects",
                    "VVDocs": "",
                    "WhereUsed": ""
                }
                output_rows.append(row)

                payload = {
                    "stage": 1,
                    "stageName": "Scanning Sidecars & Compiling CSV",
                    "progress": int(5 + (idx / max(total_items, 1)) * 45),
                    "log": f"Added model [{idx}/{total_items}]: {model_name}",
                    "totalItems": total_items,
                    "processedItems": idx
                }
                yield f"data: {json.dumps(payload)}\n\n"
            except Exception as item_err:
                payload = {
                    "stage": 1,
                    "stageName": "Scanning Sidecars & Compiling CSV",
                    "progress": int(5 + (idx / max(total_items, 1)) * 45),
                    "log": f"Error formatting {sidecar_file.name}: {item_err}",
                    "totalItems": total_items,
                    "processedItems": idx
                }
                yield f"data: {json.dumps(payload)}\n\n"
            await asyncio.sleep(0.005)

        total_thumbs = len(used_thumbnails)
        payload = {
            "stage": 2,
            "stageName": "Bundling Flat ZIP Archive",
            "progress": 55,
            "log": f"Writing catalog.csv and packaging {total_thumbs} thumbnail renders...",
            "totalItems": total_thumbs,
            "processedItems": 0
        }
        yield f"data: {json.dumps(payload)}\n\n"

        csv_buffer = io.StringIO()
        writer = csv.DictWriter(csv_buffer, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(output_rows)

        zip_buffer = io.BytesIO()
        with zipfile.ZipFile(zip_buffer, mode='w', compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("catalog.csv", csv_buffer.getvalue())
            
            for t_idx, thumb_path in enumerate(used_thumbnails, 1):
                zf.write(thumb_path, arcname=thumb_path.name)
                if t_idx % 5 == 0 or t_idx == total_thumbs:
                    payload = {
                        "stage": 2,
                        "stageName": "Bundling Flat ZIP Archive",
                        "progress": int(55 + (t_idx / max(total_thumbs, 1)) * 40),
                        "log": f"Zipped thumbnail [{t_idx}/{total_thumbs}]: {thumb_path.name}",
                        "totalItems": total_thumbs,
                        "processedItems": t_idx
                    }
                    yield f"data: {json.dumps(payload)}\n\n"
                    await asyncio.sleep(0.005)

        zip_id = str(uuid.uuid4())
        zip_buffer.seek(0)
        export_cache[zip_id] = zip_buffer.getvalue()

        payload = {
            "stage": 3,
            "stageName": "Complete",
            "progress": 100,
            "log": "ZIP Archive successfully generated!",
            "downloadKey": zip_id
        }
        yield f"data: {json.dumps(payload)}\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")

@app.get("/api/download-export/{download_key}")
def download_export(download_key: str):
    if download_key not in export_cache:
        raise HTTPException(status_code=404, detail="Export key expired or invalid.")
    
    zip_bytes = export_cache.pop(download_key)
    return StreamingResponse(
        io.BytesIO(zip_bytes),
        media_type="application/zip",
        headers={"Content-Disposition": "attachment; filename=catalog_export.zip"}
    )

@app.post("/api/save")
def save_catalog_item(payload: dict):
    asset_loc = payload.get("AssetLocation", "")
    asset_id = payload.get("AssetID", "")
    name = payload.get("Name", "")
    status_val = payload.get("Status", "Active")
    exclusion_reason = payload.get("ExclusionReason", "")

    if not name:
        raise HTTPException(status_code=400, detail="Model name is required for saving.")

    base_dir = Path.cwd()
    clean_rel_dir = asset_loc.lstrip(".").lstrip("/").replace("\\", "/")
    if clean_rel_dir.startswith("data/"):
        clean_rel_dir = clean_rel_dir[5:]

    target_path = (base_dir / clean_rel_dir).resolve()
    if not target_path.exists():
        target_path = (Path(MODELS_ROOT) / clean_rel_dir).resolve()

    if not target_path.exists():
        raise HTTPException(status_code=404, detail=f"Target model directory not found: {target_path}")

    sidecar_file = target_path / f".{name}.metadata.json"

    existing_data = {}
    if sidecar_file.exists():
        try:
            with open(sidecar_file, 'r', encoding='utf-8-sig') as f:
                existing_data = json.load(f)
        except Exception:
            pass

    enum_val = payload.get("Enumeration", "")
    matched_siso_db_item = next((item for item in siso_db if item.get("enumeration") == enum_val), {})

    try:
        size_val = float(payload.get("StorageSize", existing_data.get("storageSizeKB", 0)))
    except (ValueError, TypeError):
        size_val = existing_data.get("storageSizeKB", 0)

    sidecar_data = {
        "fileHash": existing_data.get("fileHash", payload.get("fileHash", "")),
        "assetId": asset_id or existing_data.get("assetId", ""),
        "modelName": name,
        "status": status_val,
        "exclusionReason": exclusion_reason,
        "storageSizeKB": size_val,
        "description": payload.get("Description", existing_data.get("description", "OpenFlight 3D visual asset.")),
        "inspector": {
            "lods": payload.get("LODs", existing_data.get("inspector", {}).get("lods", "")),
            "articulations": payload.get("Articulations", existing_data.get("inspector", {}).get("articulations", "")),
            "damageStates": payload.get("DamageStates", existing_data.get("inspector", {}).get("damageStates", "")),
            "appearanceStates": payload.get("AppearanceStates", existing_data.get("inspector", {}).get("appearanceStates", "")),
            "packageList": payload.get("PackageList", existing_data.get("inspector", {}).get("packageList", "")),
            "boundingBox": payload.get("Parameterisation", existing_data.get("inspector", {}).get("boundingBox", "")),
            "textureResolution": payload.get("TextureResolution", existing_data.get("inspector", {}).get("textureResolution", "")),
            "enumeration": enum_val,
            "textureWarnings": payload.get("TextureWarnings", existing_data.get("inspector", {}).get("textureWarnings", ""))
        },
        "siso": {
            "enumeration": enum_val,
            "kind": matched_siso_db_item.get("kind") or payload.get("Type") or "Platform",
            "domain": payload.get("Domain", ""),
            "countryOfOrigin": payload.get("CountryOfOrigin", ""),
            "category": matched_siso_db_item.get("category") or "",
            "type": payload.get("Type", ""),
            "subType": payload.get("SubType", "")
        }
    }

    with open(sidecar_file, 'w', encoding='utf-8') as f:
        json.dump(sidecar_data, f, indent=3)

    print(f"[SIDECAR SAVE] Saved updated metadata to: {sidecar_file}")
    return {"status": "success", "message": f"Successfully updated sidecar for {name}"}

@app.get("/search")
def search_siso(q: str, domain: str = None, limit: int = 15):
    if not q or not siso_db:
        return []

    q_clean = q.strip()

    if re.match(r'^\d+(\.\d+)*$', q_clean):
        exact_matches = []
        for entry in siso_db:
            enum_str = entry["enumeration"]
            if enum_str.startswith(q_clean) or q_clean.startswith(enum_str):
                exact_matches.append({"score": 100.0, "match": entry})
        if exact_matches:
            return exact_matches[:limit]

    q_raw = q_clean.lower()
    q_norm = re.sub(r'[^a-z0-9]', '', q_raw)

    munition_keywords = ["missile", "bomb", "torpedo", "rocket", "tomahawk", "sidewinder", "amraam", "round", "shell", "munition"]
    is_munition_query = any(k in q_raw for k in munition_keywords)

    candidate_db = siso_db
    if domain:
        dom_lower = domain.lower()
        if dom_lower == "munition" or is_munition_query:
            filtered = [
                e for e in siso_db 
                if dom_lower in e.get("domain", "").lower() 
                or e.get("kind", "").lower() == "munition" 
                or e.get("kind", "").lower() == "kind 2"
            ]
        else:
            filtered = [
                e for e in siso_db 
                if dom_lower in e.get("domain", "").lower() 
                or e.get("kind", "").lower() == "munition"
            ]
        if filtered:
            candidate_db = filtered

    matches = []
    for entry in candidate_db:
        sub_type = entry.get("subType", "").lower()
        clean_name = entry.get("cleanName", "").lower()
        search_terms = entry.get("searchTerms", "").lower()

        sub_norm = re.sub(r'[^a-z0-9]', '', sub_type)
        name_norm = re.sub(r'[^a-z0-9]', '', clean_name)

        score_sub = fuzz.token_set_ratio(q_norm, sub_norm) if sub_norm else 0
        score_name = fuzz.token_set_ratio(q_norm, name_norm) if name_norm else 0
        score_full = fuzz.token_set_ratio(q_raw, search_terms)

        score = max(score_sub, score_name, score_full)

        if q_norm in sub_norm or q_norm in name_norm:
            score = max(score, 92.0)

        matches.append({"score": min(round(score, 1), 100.0), "match": entry})

    matches.sort(key=lambda x: x["score"], reverse=True)
    return matches[:limit]

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)