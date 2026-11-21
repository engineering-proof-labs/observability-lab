package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/engineering-proof-labs/observability-lab/internal/lab"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	meterProvider, metricsHandler, err := newCheckoutMetrics()
	if err != nil {
		return fmt.Errorf("configure checkout metrics: %w", err)
	}
	defer func() {
		if err := meterProvider.Shutdown(context.Background()); err != nil {
			log.Printf("shutdown metrics: %v", err)
		}
	}()

	return lab.Run("checkout", func(mux *http.ServeMux) {
		client := &http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)}
		mux.Handle("GET /metrics", metricsHandler)
		mux.Handle("GET /checkout", otelhttp.NewHandler(checkout(client), "GET /checkout",
			otelhttp.WithMeterProvider(meterProvider),
			otelhttp.WithMetricAttributesFn(func(*http.Request) []attribute.KeyValue {
				return []attribute.KeyValue{attribute.String("http.route", "/checkout")}
			})))
	})
}

func checkout(client *http.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Trace-ID", trace.SpanContextFromContext(r.Context()).TraceID().String())
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()

		body, err := shippingQuote(ctx, client)
		if err != nil {
			log.Printf("shipping quote: %v", err)
			if errors.Is(err, context.DeadlineExceeded) {
				http.Error(w, "shipping quote timed out", http.StatusGatewayTimeout)
				return
			}
			http.Error(w, "shipping quote unavailable", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if _, err := w.Write(body); err != nil {
			log.Printf("write checkout response: %v", err)
		}
	}
}

func shippingQuote(ctx context.Context, client *http.Client) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://shipping:8080/quote", nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("shipping returned HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}
