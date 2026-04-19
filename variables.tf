variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "database_name" {
  description = "Name of the database cluster"
  type        = string
  default     = "dev-postgres"
}

variable "app_database_name" {
  description = "Name of the application database"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Database user for the application"
  type        = string
  default     = "devuser"
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "nyc3"
  validation {
    condition     = contains(["sfo3", "nyc3", "lon1", "sgp1", "blr1", "fra1", "tor1", "ams3", "ber1"], var.region)
    error_message = "Choose a valid DigitalOcean region."
  }
}
