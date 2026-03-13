package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
	"go.opentelemetry.io/otel/trace"
)

var tracer trace.Tracer
var httpClient *http.Client

type GreetRequest struct {
	Calls int      `json:"calls"`
	Chain []string `json:"chain"`
}

type GreetResponse struct {
	Message string `json:"message"`
	Service string `json:"service"`
}

type AggregatedResponse struct {
	Greetings []GreetResponse `json:"greetings"`
	TraceID   string          `json:"trace_id"`
}

func initTracer() func() {
	ctx := context.Background()

	otlpEndpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
	if otlpEndpoint == "" {
		otlpEndpoint = "otel-collector:4317"
	}

	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint(otlpEndpoint),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		log.Printf("Failed to create OTLP exporter: %v", err)
		return func() {}
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName("gateway"),
			semconv.ServiceVersion("1.0.0"),
		),
	)
	if err != nil {
		log.Printf("Failed to create resource: %v", err)
		return func() {}
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	tracer = tp.Tracer("gateway")

	return func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tp.Shutdown(ctx); err != nil {
			log.Printf("Error shutting down tracer provider: %v", err)
		}
	}
}

func loadTLSConfig() (*tls.Config, error) {
	certFile := os.Getenv("TLS_CERT_FILE")
	keyFile := os.Getenv("TLS_KEY_FILE")
	caFile := os.Getenv("TLS_CA_FILE")

	if certFile == "" || keyFile == "" || caFile == "" {
		return nil, nil // TLS not configured
	}

	// Load server certificate
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load certificate: %w", err)
	}

	// Load CA certificate
	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA certificate: %w", err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to add CA certificate to pool")
	}

	return &tls.Config{
		Certificates: []tls.Certificate{cert},
		ClientCAs:    caCertPool,
		ClientAuth:   tls.VerifyClientCertIfGiven,
		MinVersion:   tls.VersionTLS12,
	}, nil
}

func createTLSClient() (*http.Client, error) {
	certFile := os.Getenv("TLS_CERT_FILE")
	keyFile := os.Getenv("TLS_KEY_FILE")
	caFile := os.Getenv("TLS_CA_FILE")

	if certFile == "" || keyFile == "" || caFile == "" {
		// Return default client if TLS not configured
		return &http.Client{
			Transport: otelhttp.NewTransport(http.DefaultTransport),
			Timeout:   10 * time.Second,
		}, nil
	}

	// Load client certificate
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("failed to load client certificate: %w", err)
	}

	// Load CA certificate
	caCert, err := os.ReadFile(caFile)
	if err != nil {
		return nil, fmt.Errorf("failed to read CA certificate: %w", err)
	}

	caCertPool := x509.NewCertPool()
	if !caCertPool.AppendCertsFromPEM(caCert) {
		return nil, fmt.Errorf("failed to add CA certificate to pool")
	}

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		RootCAs:      caCertPool,
		MinVersion:   tls.VersionTLS12,
	}

	transport := &http.Transport{
		TLSClientConfig: tlsConfig,
	}

	return &http.Client{
		Transport: otelhttp.NewTransport(transport),
		Timeout:   10 * time.Second,
	}, nil
}

func getServiceURL(service string) string {
	useTLS := os.Getenv("TLS_CERT_FILE") != ""
	scheme := "http"
	if useTLS {
		scheme = "https"
	}

	switch service {
	case "greeter":
		host := os.Getenv("GREETER_HOST")
		if host == "" {
			host = "greeter:8081"
		}
		return fmt.Sprintf("%s://%s/greet", scheme, host)
	case "echo":
		host := os.Getenv("ECHO_HOST")
		if host == "" {
			host = "echo:8082"
		}
		return fmt.Sprintf("%s://%s/greet", scheme, host)
	case "hola":
		host := os.Getenv("HOLA_HOST")
		if host == "" {
			host = "hola:8083"
		}
		return fmt.Sprintf("%s://%s/greet", scheme, host)
	default:
		return ""
	}
}

func callService(ctx context.Context, service string) (*GreetResponse, error) {
	ctx, span := tracer.Start(ctx, fmt.Sprintf("call-%s", service))
	defer span.End()

	span.SetAttributes(attribute.String("target.service", service))

	url := getServiceURL(service)
	if url == "" {
		return nil, fmt.Errorf("unknown service: %s", service)
	}

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}

	otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))

	resp, err := httpClient.Do(req)
	if err != nil {
		span.RecordError(err)
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var greetResp GreetResponse
	if err := json.Unmarshal(body, &greetResp); err != nil {
		return nil, err
	}

	return &greetResp, nil
}

func greetHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	span := trace.SpanFromContext(ctx)

	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req GreetRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	span.SetAttributes(
		attribute.Int("request.calls", req.Calls),
		attribute.StringSlice("request.chain", req.Chain),
	)

	greetings := []GreetResponse{
		{Message: "Hallo", Service: "gateway"},
	}

	for i := 0; i < req.Calls; i++ {
		for _, service := range req.Chain {
			resp, err := callService(ctx, service)
			if err != nil {
				log.Printf("Error calling %s: %v", service, err)
				span.RecordError(err)
				continue
			}
			greetings = append(greetings, *resp)
		}
	}

	response := AggregatedResponse{
		Greetings: greetings,
		TraceID:   span.SpanContext().TraceID().String(),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "healthy"})
}

func main() {
	cleanup := initTracer()
	defer cleanup()

	// Initialize HTTP client (with or without TLS)
	var err error
	httpClient, err = createTLSClient()
	if err != nil {
		log.Fatalf("Failed to create TLS client: %v", err)
	}

	mux := http.NewServeMux()

	mux.Handle("/", http.FileServer(http.Dir("static")))
	mux.HandleFunc("/greet", greetHandler)
	mux.HandleFunc("/health", healthHandler)

	handler := otelhttp.NewHandler(mux, "gateway")

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// Load TLS configuration
	tlsConfig, err := loadTLSConfig()
	if err != nil {
		log.Fatalf("Failed to load TLS config: %v", err)
	}

	server := &http.Server{
		Addr:    ":" + port,
		Handler: handler,
	}

	if tlsConfig != nil {
		server.TLSConfig = tlsConfig
		log.Printf("Gateway service starting on port %s with mTLS", port)
		if err := server.ListenAndServeTLS("", ""); err != nil {
			log.Fatalf("Server failed: %v", err)
		}
	} else {
		log.Printf("Gateway service starting on port %s (no TLS)", port)
		if err := server.ListenAndServe(); err != nil {
			log.Fatalf("Server failed: %v", err)
		}
	}
}
