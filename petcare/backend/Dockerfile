# Imagem usada apenas no ambiente local (docker-compose).
FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags "-s -w" -o petcare-backend .

FROM alpine:3.22
RUN apk --no-cache add ca-certificates tzdata && adduser -D -H -u 10001 petcare
ENV TZ=America/Sao_Paulo
WORKDIR /app
COPY --from=builder /app/petcare-backend .
USER petcare
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/health || exit 1
CMD ["./petcare-backend"]
