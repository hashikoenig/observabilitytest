require('./tracing');

const express = require('express');
const https = require('https');
const http = require('http');
const fs = require('fs');
const { trace, SpanStatusCode, context, propagation } = require('@opentelemetry/api');

const app = express();
const port = process.env.PORT || 8082;

const tracer = trace.getTracer('echo-service');

app.use(express.json());

app.get('/greet', (req, res) => {
  // Extract trace context from incoming request headers
  const parentContext = propagation.extract(context.active(), req.headers);

  // Create child span within the extracted context
  context.with(parentContext, () => {
    const span = tracer.startSpan('process-greeting');

    span.setAttribute('greeting.language', 'english');
    span.setAttribute('greeting.message', 'Hello');

    const response = {
      message: 'Hello',
      service: 'echo'
    };

    span.setStatus({ code: SpanStatusCode.OK });
    span.end();

    res.json(response);
  });
});

app.get('/health', (req, res) => {
  res.json({ status: 'healthy' });
});

const certFile = process.env.TLS_CERT_FILE;
const keyFile = process.env.TLS_KEY_FILE;
const caFile = process.env.TLS_CA_FILE;

if (certFile && keyFile && caFile) {
  const options = {
    cert: fs.readFileSync(certFile),
    key: fs.readFileSync(keyFile),
    ca: fs.readFileSync(caFile),
    requestCert: true,
    rejectUnauthorized: true
  };

  https.createServer(options, app).listen(port, () => {
    console.log(`Echo service listening on port ${port} with mTLS`);
  });
} else {
  http.createServer(app).listen(port, () => {
    console.log(`Echo service listening on port ${port} (no TLS)`);
  });
}
