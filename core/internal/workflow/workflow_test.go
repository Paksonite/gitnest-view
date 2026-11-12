package workflow

import (
	"reflect"
	"testing"
)

func TestParse(t *testing.T) {
	info, err := Parse([]byte(`
name: Drift detection
run-name: ${{ forgejo.actor }} checks drift
on:
  schedule:
    - cron: "0 5 * * 1"
  workflow_dispatch:
    inputs:
      environment:
        description: Which environment
        required: true
        type: choice
        default: prod
        options: [prod, test]
      dry_run:
        type: boolean
        default: true
      note:
        description: Free text
jobs: {}
`))
	if err != nil {
		t.Fatal(err)
	}
	if info.Name != "Drift detection" || !info.Dispatch {
		t.Fatalf("%+v", info)
	}
	if !reflect.DeepEqual(info.Events, []string{"schedule", "workflow_dispatch"}) {
		t.Errorf("events: %v", info.Events)
	}
	want := []Input{
		{Name: "environment", Description: "Which environment", Required: true, Default: "prod", Type: "choice", Options: []string{"prod", "test"}},
		{Name: "dry_run", Default: "true", Type: "boolean", Options: []string{}},
		{Name: "note", Description: "Free text", Type: "string", Options: []string{}},
	}
	if !reflect.DeepEqual(info.Inputs, want) {
		t.Errorf("inputs:\n got %+v\nwant %+v", info.Inputs, want)
	}
}

func TestParseTriggerForms(t *testing.T) {
	for src, wantDispatch := range map[string]bool{
		"on: push\n":              false,
		"on: workflow_dispatch\n": true,
		"on: [push, pull_request, workflow_dispatch]\n": true,
		"on:\n  workflow_dispatch:\n  push:\n":          true,
		"name: no trigger\n":                            false,
	} {
		info, err := Parse([]byte(src))
		if err != nil || info.Dispatch != wantDispatch {
			t.Errorf("%q: dispatch=%v err=%v", src, info.Dispatch, err)
		}
		if info.Inputs == nil || info.Events == nil {
			t.Errorf("%q: lists must not be null in JSON", src)
		}
	}
	if _, err := Parse([]byte("- a\n- b\n")); err == nil {
		t.Error("a list is not a workflow")
	}
	if _, err := Parse([]byte("a: [unclosed")); err == nil {
		t.Error("broken YAML must fail")
	}
}
