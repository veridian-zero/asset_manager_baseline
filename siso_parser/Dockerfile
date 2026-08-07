FROM python:3.11-slim

WORKDIR /app

# Install lxml for fast XML parsing & rapidfuzz for ultra-fast C++ fuzzy matching
RUN pip install --no-cache-dir lxml rapidfuzz fastapi uvicorn sse-starlette

COPY siso_parse.py /app/
COPY server.py /app/
COPY index.html /app/

# Port for fuzzy lookup API
EXPOSE 8000

CMD ["python", "server.py"]