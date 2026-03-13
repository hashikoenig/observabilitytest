import os
import ssl
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.semconv.resource import ResourceAttributes
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.propagate import inject

resource = Resource.create({
    ResourceAttributes.SERVICE_NAME: "greeter",
    ResourceAttributes.SERVICE_VERSION: "1.0.0",
})

otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "otel-collector:4317")

provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
processor = BatchSpanProcessor(exporter)
provider.add_span_processor(processor)
trace.set_tracer_provider(provider)

tracer = trace.get_tracer(__name__)

app = FastAPI(title="Greeter Service")

FastAPIInstrumentor.instrument_app(app)
HTTPXClientInstrumentor().instrument()


def get_ssl_context():
    """Create SSL context for client connections."""
    cert_file = os.getenv("TLS_CERT_FILE")
    key_file = os.getenv("TLS_KEY_FILE")
    ca_file = os.getenv("TLS_CA_FILE")

    if not all([cert_file, key_file, ca_file]):
        return None

    ssl_context = ssl.create_default_context(ssl.Purpose.SERVER_AUTH)
    ssl_context.load_cert_chain(certfile=cert_file, keyfile=key_file)
    ssl_context.load_verify_locations(cafile=ca_file)
    ssl_context.check_hostname = False
    return ssl_context


def get_service_url(service: str) -> str:
    use_tls = os.getenv("TLS_CERT_FILE") is not None
    scheme = "https" if use_tls else "http"

    if service == "echo":
        host = os.getenv("ECHO_HOST", "echo:8082")
        return f"{scheme}://{host}"
    return None


@app.get("/greet")
async def greet(request: Request):
    with tracer.start_as_current_span("process-greeting") as span:
        span.set_attribute("greeting.language", "french")
        span.set_attribute("greeting.message", "Bonjour")

        return JSONResponse({
            "message": "Bonjour",
            "service": "greeter"
        })


@app.get("/greet/chain")
async def greet_chain(request: Request, next_service: str = None):
    with tracer.start_as_current_span("process-greeting-chain") as span:
        span.set_attribute("greeting.language", "french")

        result = {
            "message": "Bonjour",
            "service": "greeter",
            "chain": []
        }

        if next_service:
            service_url = get_service_url(next_service)
            if service_url:
                with tracer.start_as_current_span(f"call-{next_service}") as call_span:
                    call_span.set_attribute("target.service", next_service)
                    headers = {}
                    inject(headers)

                    ssl_context = get_ssl_context()
                    client_kwargs = {"timeout": 10.0}
                    if ssl_context:
                        client_kwargs["verify"] = ssl_context

                    async with httpx.AsyncClient(**client_kwargs) as client:
                        try:
                            response = await client.get(
                                f"{service_url}/greet",
                                headers=headers,
                            )
                            if response.status_code == 200:
                                result["chain"].append(response.json())
                        except Exception as e:
                            call_span.record_exception(e)

        return JSONResponse(result)


@app.get("/health")
async def health():
    return JSONResponse({"status": "healthy"})


if __name__ == "__main__":
    import uvicorn

    port = int(os.getenv("PORT", "8081"))

    cert_file = os.getenv("TLS_CERT_FILE")
    key_file = os.getenv("TLS_KEY_FILE")
    ca_file = os.getenv("TLS_CA_FILE")

    ssl_kwargs = {}
    if all([cert_file, key_file, ca_file]):
        ssl_kwargs["ssl_certfile"] = cert_file
        ssl_kwargs["ssl_keyfile"] = key_file
        ssl_kwargs["ssl_ca_certs"] = ca_file
        ssl_kwargs["ssl_cert_reqs"] = ssl.CERT_REQUIRED
        print(f"Starting greeter service on port {port} with mTLS")
    else:
        print(f"Starting greeter service on port {port} (no TLS)")

    uvicorn.run(app, host="0.0.0.0", port=port, **ssl_kwargs)
