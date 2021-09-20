provider "google"{
    credentials = "${file("ce-mohammedmagdi.json")}" 
    region = "us-west2"
}
resource "random_integer" "int" {
  min = 100
  max = 1000000
}
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 3.66"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}
locals {
  region               = "us-west2"
  org_id               = "ce-mohammedmagdi"
  host_project_name    = "host-dev"
  service_project_name = "k8s-dev"
  host_project_id      = "${local.host_project_name}-${random_integer.int.result}"
  service_project_id   = "${local.service_project_name}-${random_integer.int.result}"
  projects_api         = "container.googleapis.com"
  secondary_ip_ranges = {
    "pod-ip-range"      = "10.0.0.0/14",
    "services-ip-range" = "10.4.0.0/19"
  }
}
resource "google_project" "host-dev" {
  name                = local.host_project_name
  project_id          = local.host_project_id
  org_id              = local.org_id
  auto_create_network = false
}
resource "google_project" "k8s-dev" {
  name                = local.service_project_name
  project_id          = local.service_project_id
  org_id              = local.org_id
  auto_create_network = false
}
resource "google_project_service" "host" {
  project = google_project.host-dev.number
  service = local.projects_api
}
resource "google_project_service" "service" {
  project = google_project.k8s-dev.number
  service = local.projects_api
}
resource "google_compute_network" "main" {
  name                    = "main"
  project                 = google_compute_shared_vpc_host_project.host.project
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  mtu                     = 1500
}
resource "google_compute_subnetwork" "private" {
  name                     = "private"
  project                  = google_compute_shared_vpc_host_project.host.project
  ip_cidr_range            = "10.5.0.0/20"
  region                   = local.region
  network                  = google_compute_network.main.self_link
  private_ip_google_access = true
  dynamic "secondary_ip_range" {
    for_each = local.secondary_ip_ranges

    content {
      range_name    = secondary_ip_range.key
      ip_cidr_range = secondary_ip_range.value
    }
  }
}
resource "google_compute_router" "router" {
  name    = "router"
  region  = local.region
  project = local.host_project_id
  network = google_compute_network.main.self_link
}
resource "google_compute_router_nat" "mist_nat" {
  name                               = "nat"
  project                            = local.host_project_id
  router                             = google_compute_router.router.name
  region                             = local.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  depends_on = [google_compute_subnetwork.private]
}
resource "google_compute_shared_vpc_host_project" "host" {
  project = google_project.host-dev.number
}
resource "google_compute_shared_vpc_service_project" "service" {
  host_project    = local.host_project_id
  service_project = local.service_project_id

  depends_on = [google_compute_shared_vpc_host_project.host]
}
resource "google_compute_subnetwork_iam_binding" "binding" {
  project    = google_compute_shared_vpc_host_project.host.project
  region     = google_compute_subnetwork.private.region
  subnetwork = google_compute_subnetwork.private.name

  role = "roles/compute.networkUser"
  members = [
    "serviceAccount:${google_service_account.k8s-dev.email}",
    "serviceAccount:${google_project.k8s-dev.number}@cloudservices.gserviceaccount.com",
    "serviceAccount:service-${google_project.k8s-dev.number}@container-engine-robot.iam.gserviceaccount.com"
  ]
}
resource "google_project_iam_binding" "container-engine" {
  project = google_compute_shared_vpc_host_project.host.project
  role    = "roles/container.hostServiceAgentUser"

  members = [
    "serviceAccount:service-${google_project.k8s-dev.number}@container-engine-robot.iam.gserviceaccount.com",
  ]
  depends_on = [google_project_service.service]
}
resource "google_service_account" "k8s-dev" {
  project    = local.service_project_id
  account_id = "k8s-dev"

  depends_on = [google_project.k8s-dev]
}
resource "google_container_cluster" "gke" {
  name     = "gke"
  location = local.region
  project  = local.service_project_id

  networking_mode = "VPC_NATIVE"
  network         = google_compute_network.main.self_link
  subnetwork      = google_compute_subnetwork.private.self_link

  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = "REGULAR"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pod-ip-range"
    services_secondary_range_name = "services-ip-range"
  }

  network_policy {
    provider = "PROVIDER_UNSPECIFIED"
    enabled  = true
  }

  private_cluster_config {
    enable_private_endpoint = false
    enable_private_nodes    = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  workload_identity_config {
    identity_namespace = "${google_project.k8s-dev.project_id}.svc.id.goog"
  }

}
resource "google_container_node_pool" "general" {
  name       = "general"
  location   = local.region
  cluster    = google_container_cluster.gke.name
  project    = local.service_project_id
  node_count = 2
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  resource "google_compute_autoscaler" "default" {
  provider = google-beta

  name   = "my-autoscaler"
  zone   = "us-west2-f"
  target = google_compute_instance_group_manager.default.id

  autoscaling_policy {
    max_replicas    = 10
    min_replicas    = 2
    cooldown_period = 60

    metric {
      name                       = "pubsub.googleapis.com/subscription/num_undelivered_messages"
      filter                     = "resource.type = pubsub_subscription AND resource.label.subscription_id = our-subscription"
      single_instance_assignment = 65535
    }
  }
}

  node_config {
    labels = {
      role = "general"
    }
    machine_type = "e2-medium"

    service_account = google_service_account.k8s-dev.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}
resource "google_compute_firewall" "lb" {
  name        = ""#from-the-description-of-the-nginx-pod#""
  network     = google_compute_network.main.name
  project     = local.host_project_id
  description = "{"#from-the-description-of-the-nginx-pod#"}"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["#from-the-description-of-the-nginx-pod#"]
}

resource "google_compute_firewall" "health" {
  name        = "#from-the-description-of-the-nginx-pod#""
  network     = google_compute_network.main.name
  project     = local.host_project_id
  description = "{#from-the-description-of-the-nginx-pod#"}"

  allow {
    protocol = "tcp"
    ports    = ["10256"]
  }

  source_ranges = ["130.211.0.0/22", "209.85.152.0/22", "209.85.204.0/22", "35.191.0.0/16"]
  target_tags   = ["#from-the-description-of-the-nginx-pod#"]
}
