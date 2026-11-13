FROM golang:1.27.4-alpine AS dependencies
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .

FROM dependencies AS test
RUN apk add --no-cache gcc musl-dev
CMD ["go", "test", "-race", "-count=1", "./..."]

FROM dependencies AS build
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api

FROM alpine:3.24 AS runtime
RUN apk add --no-cache ca-certificates tzdata
COPY --from=build /out/api /usr/local/bin/pocket-api
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/pocket-api"]
