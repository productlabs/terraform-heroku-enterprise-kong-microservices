variable "name" {
  type = "string"
}

variable "dns_zone" {
  type        = "string"
  description = "DNS zone for new records (must already be setup in the DNSimple account)"
}

variable "heroku_enterprise_team" {
  type = "string"
}

variable "heroku_private_region" {
  type    = "string"
  default = "oregon"
}

variable "hello_world_header_message" {
  type        = "string"
  description = "Custom message to output in heroku-kong's 'Hello-World' HTTP header."
  default     = "🌞💎"
}

locals {
  kong_app_name           = "${var.name}-proxy"
  kong_base_url           = "https://${local.kong_app_name}.${var.dns_zone}"
  kong_insecure_base_url  = "http://${local.kong_app_name}.herokuapp.com"
  kong_admin_uri          = "${local.kong_base_url}/kong-admin"
  kong_insecure_admin_uri = "${local.kong_insecure_base_url}/kong-admin"
}

provider "dnsimple" {
  version = "~> 0.1"
}

provider "heroku" {
  version = "~> 1.4"
}

provider "kong" {
  version = "~> 1.7"

  # Optional: use insecure until DNS is ready at dnsimple
  # kong_admin_uri = "${local.kong_insecure_admin_uri}"
  kong_admin_uri = "${local.kong_admin_uri}"
  kong_api_key   = "${random_id.kong_admin_api_key.b64_url}"
}

provider "random" {
  version = "~> 2.0"
}

resource "random_id" "kong_admin_api_key" {
  byte_length = 32
}

# Private Space

resource "heroku_space" "default" {
  name         = "${var.name}"
  organization = "${var.heroku_enterprise_team}"
  region       = "${var.heroku_private_region}"
}

# Proxy app

resource "heroku_app" "kong" {
  name  = "${local.kong_app_name}"
  space = "${heroku_space.default.name}"
  acm   = true

  config_vars {
    KONG_HEROKU_ADMIN_KEY = "${random_id.kong_admin_api_key.b64_url}"
    HELLO_WORLD_MESSAGE   = "${var.hello_world_header_message}"
  }

  organization = {
    name = "${var.heroku_enterprise_team}"
  }

  region = "${var.heroku_private_region}"
}

resource "heroku_domain" "kong" {
  app        = "${heroku_app.kong.id}"
  hostname   = "${heroku_app.kong.name}.${var.dns_zone}"
}

resource "dnsimple_record" "kong" {
  domain = "${var.dns_zone}"
  name   = "${heroku_app.kong.name}"
  value  = "${heroku_domain.kong.cname}"
  type   = "CNAME"
  ttl    = 30
}

resource "heroku_addon" "kong_pg" {
  app  = "${heroku_app.kong.id}"
  plan = "heroku-postgresql:private-0"
}

resource "heroku_slug" "kong" {
  app                            = "${heroku_app.kong.id}"
  buildpack_provided_description = "Kong"
  file_path                      = "slugs/kong-auto-admin.tgz"

  process_types = {
    release = "bin/heroku-buildpack-kong-release"
    web     = "bin/heroku-buildpack-kong-web"
  }
}

resource "heroku_app_release" "kong" {
  app     = "${heroku_app.kong.id}"
  slug_id = "${heroku_slug.kong.id}"

  depends_on = ["heroku_addon.kong_pg"]
}

resource "heroku_formation" "kong" {
  app        = "${heroku_app.kong.id}"
  type       = "web"
  quantity   = 1
  size       = "Private-S"
  depends_on = ["heroku_app_release.kong", "dnsimple_record.kong"]

  provisioner "local-exec" {
    # Optional: use insecure until DNS is ready at dnsimple
    # command = "./bin/kong-health-check ${local.kong_insecure_base_url}/kong-admin"
    command = "./bin/kong-health-check ${local.kong_base_url}/kong-admin"
  }
}

# Internal app w/ proxy config

resource "heroku_app" "wasabi" {
  name             = "${var.name}-wasabi"
  space            = "${heroku_space.default.name}"
  internal_routing = true

  organization = {
    name = "${var.heroku_enterprise_team}"
  }

  region = "${var.heroku_private_region}"
}

resource "heroku_slug" "wasabi" {
  app                            = "${heroku_app.wasabi.id}"
  buildpack_provided_description = "Node.js"
  file_path                      = "slugs/wasabi.tgz"

  process_types = {
    web = "npm start"
  }
}

resource "heroku_app_release" "wasabi" {
  app     = "${heroku_app.wasabi.id}"
  slug_id = "${heroku_slug.wasabi.id}"
}

resource "heroku_formation" "wasabi" {
  app        = "${heroku_app.wasabi.id}"
  type       = "web"
  quantity   = 1
  size       = "Private-S"
  depends_on = ["heroku_app_release.wasabi"]
}

resource "kong_service" "wasabi" {
  name       = "wasabi"
  protocol   = "http"
  host       = "${heroku_app.wasabi.name}.herokuapp.com"
  port       = 80
  depends_on = ["heroku_formation.kong"]
}

resource "kong_route" "wasabi_hostname" {
  protocols  = ["https"]
  hosts      = [ "${heroku_app.wasabi.name}.${var.dns_zone}" ]
  strip_path = true
  service_id = "${kong_service.wasabi.id}"
}

resource "heroku_domain" "wasabi" {
  # The internal app's public DNS name is created on the Kong proxy.
  app        = "${heroku_app.kong.id}"
  hostname   = "${heroku_app.wasabi.name}.${var.dns_zone}"
}

resource "dnsimple_record" "wasabi" {
  domain = "${var.dns_zone}"
  name   = "${heroku_app.wasabi.name}"
  value  = "${heroku_domain.wasabi.cname}"
  type   = "CNAME"
  ttl    = 30
}

resource "kong_plugin" "wasabi_hello_world" {
  name     = "hello-world-header"
  service_id = "${kong_service.wasabi.id}"
}

output "wasabi_service_url" {
  # Optional: use insecure until DNS is ready at dnsimple
  # value = "${local.kong_insecure_base_url}/wasabi"
  value = "https://${heroku_app.wasabi.name}.${var.dns_zone}"
}
