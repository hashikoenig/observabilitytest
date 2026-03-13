storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8210"
  tls_disable = 1
}

api_addr = "http://127.0.0.1:8210"

ui = true
disable_mlock = true
