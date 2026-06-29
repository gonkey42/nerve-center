ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.21
FROM $BUILD_FROM

RUN apk add --no-cache python3

WORKDIR /app
COPY run.py /app/run.py

EXPOSE 9567

CMD ["/command/with-contenv", "python3", "/app/run.py"]
