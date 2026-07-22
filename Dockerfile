FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY hello.py .
COPY templates/ templates/
COPY static/ static/

# Run as non-root
RUN useradd -m appuser
USER appuser

EXPOSE 8000

CMD ["python", "hello.py"]