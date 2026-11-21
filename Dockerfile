FROM golang:1.26.9-alpine@sha256:3082400e369fa24d5fc60bca20edab3f6d604e0c5a690ec66b295eff4dd87ade AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN CGO_ENABLED=0 go build -trimpath -o /out/ ./cmd/...

FROM alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS runtime
USER 65534:65534

FROM runtime AS checkout
COPY --from=build /out/checkout /usr/local/bin/checkout
ENTRYPOINT ["/usr/local/bin/checkout"]

FROM runtime AS shipping
COPY --from=build /out/shipping /usr/local/bin/shipping
ENTRYPOINT ["/usr/local/bin/shipping"]
