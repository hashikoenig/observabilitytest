package com.observability.hola;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.propagation.TextMapGetter;
import io.opentelemetry.api.GlobalOpenTelemetry;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Collections;
import java.util.Map;

@RestController
public class GreetController {

    private final Tracer tracer;

    private static final TextMapGetter<HttpServletRequest> getter = new TextMapGetter<>() {
        @Override
        public Iterable<String> keys(HttpServletRequest carrier) {
            return Collections.list(carrier.getHeaderNames());
        }

        @Override
        public String get(HttpServletRequest carrier, String key) {
            return carrier.getHeader(key);
        }
    };

    @Autowired
    public GreetController(Tracer tracer) {
        this.tracer = tracer;
    }

    @GetMapping("/greet")
    public Map<String, String> greet(HttpServletRequest request) {
        // Extract trace context from incoming request headers
        Context extractedContext = GlobalOpenTelemetry.getPropagators()
            .getTextMapPropagator()
            .extract(Context.current(), request, getter);

        Span span = tracer.spanBuilder("process-greeting")
            .setParent(extractedContext)
            .startSpan();
        try {
            span.setAttribute("greeting.language", "spanish");
            span.setAttribute("greeting.message", "Hola");

            return Map.of(
                "message", "Hola",
                "service", "hola"
            );
        } finally {
            span.end();
        }
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "healthy");
    }
}
