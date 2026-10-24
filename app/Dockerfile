FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY service.py .
RUN useradd -u 10001 app
USER 10001
EXPOSE 8080
CMD ["python", "service.py"]
