package hcl

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestScan(t *testing.T) {
	root := t.TempDir()
	write := func(path, text string) {
		full := filepath.Join(root, path)
		os.MkdirAll(filepath.Dir(full), 0o755)
		if err := os.WriteFile(full, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("main.tf", `# The DNS zones
module "cloud_dns" {
  source   = "../terraform-modules//dns"
  for_each = var.zones
  name     = each.key
}

resource "google_dns_record_set" "api" {
  name = "api"
  lifecycle {
    # source = "not a module source"
  }
}

data "google_project" "this" {}
`)
	write("modules/inner/x.tf", `resource "null_resource" "x" {
  count = 2
}`)
	write(".terraform/modules/ignored.tf", `resource "ignored" "x" {}`)
	write("live/prod/gke/terragrunt.hcl", `terraform {
  source = "git::https://forge.example/mods.git//gke?ref=v1"
}
inputs = { node_count = 4 }
`)

	items, err := Scan(root, 100)
	if err != nil {
		t.Fatal(err)
	}
	want := []Item{
		{Kind: "unit", Name: "live/prod/gke", File: "live/prod/gke/terragrunt.hcl", Line: 1, Source: "git::https://forge.example/mods.git//gke?ref=v1"},
		{Kind: "module", Name: "cloud_dns", File: "main.tf", Line: 2, Source: "../terraform-modules//dns", Many: true},
		{Kind: "resource", Type: "google_dns_record_set", Name: "api", File: "main.tf", Line: 8},
		{Kind: "data", Type: "google_project", Name: "this", File: "main.tf", Line: 15},
		{Kind: "resource", Type: "null_resource", Name: "x", File: "modules/inner/x.tf", Line: 1, Many: true},
	}
	if !reflect.DeepEqual(items, want) {
		t.Errorf("got\n%+v\nwant\n%+v", items, want)
	}
	if items[1].Address() != "module.cloud_dns" || items[3].Address() != "data.google_project.this" {
		t.Errorf("addresses: %s %s", items[1].Address(), items[3].Address())
	}
}
