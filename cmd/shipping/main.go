package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/engineering-proof-labs/observability-lab/internal/lab"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

func main() {
	delay := os.Getenv("SHIPPING_DELAY_MS")
	if delay == "" {
		delay = "0"
	}
	delayMs, err := strconv.Atoi(delay)
	if err != nil || delayMs < 0 || delayMs > 900 {
		log.Fatal("SHIPPING_DELAY_MS must be an integer from 0 to 900")
	}
	log.Printf("shipping delay configured to %d ms", delayMs)

	if err := lab.Run("shipping", func(mux *http.ServeMux) {
		tracer := otel.Tracer("observability-lab/shipping")
		mux.Handle("GET /quote", otelhttp.NewHandler(quote(tracer, delayMs), "GET /quote"))
	}); err != nil {
		log.Fatal(err)
	}
}

func quote(tracer trace.Tracer, delayMs int) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := waitForQuote(r.Context(), tracer, delayMs); err != nil {
			http.Error(w, "shipping request canceled", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if _, err := w.Write([]byte("{\"shipping_cents\":499,\"currency\":\"USD\"}\n")); err != nil {
			log.Printf("write shipping quote: %v", err)
		}
	}
}

func waitForQuote(ctx context.Context, tracer trace.Tracer, delayMs int) error {
	ctx, span := tracer.Start(ctx, "shipping.delay",
		trace.WithAttributes(attribute.Int("lab.shipping.delay_ms", delayMs)))
	defer span.End()

	if delayMs == 0 {
		return nil
	}
	timer := time.NewTimer(time.Duration(delayMs) * time.Millisecond)
	defer timer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		err := ctx.Err()
		span.SetStatus(codes.Error, err.Error())
		return err
	}
}
