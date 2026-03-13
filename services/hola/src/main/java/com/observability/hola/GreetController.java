package com.observability.hola;

import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.Tracer;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
public class GreetController {

    private final Tracer tracer;

    @Autowired
    public GreetController(Tracer tracer) {
        this.tracer = tracer;
    }

    @GetMapping("/greet")
    public Map<String, String> greet() {
        Span span = tracer.spanBuilder("process-greeting").startSpan();
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
