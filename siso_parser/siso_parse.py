import json
from lxml import etree

def parse_siso_xml(xml_path, output_json_path):
    tree = etree.parse(xml_path)
    root = tree.getroot()

    ns = {'siso': 'http://www.sisostds.org/schemas/SISO-REF-010/2.7'}

    kinds = {}
    domains = {}
    countries = {}

    for enum_elem in root.findall('siso:enum', ns):
        uid = enum_elem.get('uid')
        if uid == '7':
            for row in enum_elem.findall('siso:enumrow', ns):
                kinds[row.get('value')] = row.get('description')
        elif uid == '8':
            for row in enum_elem.findall('siso:enumrow', ns):
                domains[row.get('value')] = row.get('description')
        elif uid == '29':
            for row in enum_elem.findall('siso:enumrow', ns):
                countries[row.get('value')] = row.get('description')

    index = []

    def parse_entities(container_tag):
        for container in root.findall(f'siso:{container_tag}', ns):
            for entity in container.findall('siso:entity', ns):
                kind = entity.get('kind', '0')
                domain = entity.get('domain', '0')
                country = entity.get('country', '0')

                kind_str = kinds.get(kind, f"Kind {kind}")
                domain_str = domains.get(domain, f"Domain {domain}")
                country_str = countries.get(country, f"Country {country}")

                if kind == '2' or kind_str.lower() == 'munition':
                    domain_str = "Munition"

                for cat in entity.findall('siso:category', ns):
                    cat_val = cat.get('value', '0')
                    cat_desc = cat.get('description', '')

                    for subcat in cat.findall('siso:subcategory', ns):
                        sub_val = subcat.get('value', '0')
                        sub_desc = subcat.get('description', '')

                        specs = subcat.findall('siso:specific', ns)
                        
                        sub_code = f"{kind}.{domain}.{country}.{cat_val}.{sub_val}.0.0"
                        index.append({
                            "enumeration": sub_code,
                            "kind": kind_str,
                            "domain": domain_str,
                            "country": country_str,
                            "category": cat_desc,
                            "type": cat_desc,
                            "subType": sub_desc,
                            "cleanName": sub_desc,
                            "searchTerms": f"{sub_desc} {cat_desc} {country_str} {domain_str} {kind_str} {sub_code}".lower()
                        })

                        for spec in specs:
                            spec_val = spec.get('value', '0')
                            spec_desc = spec.get('description', '')

                            extras = spec.findall('siso:extra', ns)
                            
                            spec_code = f"{kind}.{domain}.{country}.{cat_val}.{sub_val}.{spec_val}.0"
                            index.append({
                                "enumeration": spec_code,
                                "kind": kind_str,
                                "domain": domain_str,
                                "country": country_str,
                                "category": cat_desc,
                                "type": cat_desc,
                                "subType": f"{sub_desc} - {spec_desc}",
                                "cleanName": spec_desc,
                                "searchTerms": f"{spec_desc} {sub_desc} {cat_desc} {country_str} {domain_str} {kind_str} {spec_code}".lower()
                            })

                            for extra in extras:
                                extra_val = extra.get('value', '0')
                                extra_desc = extra.get('description', '')
                                extra_code = f"{kind}.{domain}.{country}.{cat_val}.{sub_val}.{spec_val}.{extra_val}"
                                index.append({
                                    "enumeration": extra_code,
                                    "kind": kind_str,
                                    "domain": domain_str,
                                    "country": country_str,
                                    "category": cat_desc,
                                    "type": cat_desc,
                                    "subType": f"{sub_desc} - {spec_desc} ({extra_desc})",
                                    "cleanName": extra_desc,
                                    "searchTerms": f"{extra_desc} {spec_desc} {sub_desc} {cat_desc} {country_str} {domain_str} {kind_str} {extra_code}".lower()
                                })

    parse_entities('cet')
    parse_entities('cot')

    print(f"Generated {len(index)} total SISO enumeration entries!")
    with open(output_json_path, 'w', encoding='utf-8') as f:
        json.dump(index, f, indent=2)

if __name__ == "__main__":
    parse_siso_xml("/data/SISO-REF-010.xml", "/data/siso_db.json")