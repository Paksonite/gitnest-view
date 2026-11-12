// Package workflow reads what GitNest View needs from an Actions workflow
// file: its name, and whether and with which inputs it can be started by hand.
package workflow

import (
	"errors"
	"fmt"

	"gopkg.in/yaml.v3"
)

// Input is one input of a workflow_dispatch trigger.
type Input struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Required    bool     `json:"required"`
	Default     string   `json:"default"`
	Type        string   `json:"type"` // string, boolean, choice, number, environment
	Options     []string `json:"options"`
}

// Info describes a workflow file.
type Info struct {
	Name string `json:"name"`
	// Dispatch: the workflow has a workflow_dispatch trigger.
	Dispatch bool     `json:"dispatch"`
	Inputs   []Input  `json:"inputs"`
	Events   []string `json:"events"`
}

// Parse reads a workflow's YAML. Inputs keep the order of the file.
func Parse(content []byte) (Info, error) {
	info := Info{Inputs: []Input{}, Events: []string{}}
	var doc yaml.Node
	if err := yaml.Unmarshal(content, &doc); err != nil {
		return info, err
	}
	if len(doc.Content) == 0 || doc.Content[0].Kind != yaml.MappingNode {
		return info, errors.New("not a workflow: the file is not a YAML mapping")
	}
	root := doc.Content[0]
	if n := child(root, "name"); n != nil && n.Kind == yaml.ScalarNode {
		info.Name = n.Value
	}
	// YAML 1.1 reads a bare `on` as the boolean true; accept both spellings.
	on := child(root, "on")
	if on == nil {
		on = child(root, "true")
	}
	if on == nil {
		return info, nil
	}
	switch on.Kind {
	case yaml.ScalarNode:
		info.Events = append(info.Events, on.Value)
	case yaml.SequenceNode:
		for _, e := range on.Content {
			info.Events = append(info.Events, e.Value)
		}
	case yaml.MappingNode:
		for i := 0; i+1 < len(on.Content); i += 2 {
			info.Events = append(info.Events, on.Content[i].Value)
		}
	}
	for _, e := range info.Events {
		if e == "workflow_dispatch" {
			info.Dispatch = true
		}
	}
	if on.Kind != yaml.MappingNode {
		return info, nil
	}
	inputs := child(child(on, "workflow_dispatch"), "inputs")
	if inputs == nil || inputs.Kind != yaml.MappingNode {
		return info, nil
	}
	for i := 0; i+1 < len(inputs.Content); i += 2 {
		in := Input{Name: inputs.Content[i].Value, Type: "string", Options: []string{}}
		spec := inputs.Content[i+1]
		if d := child(spec, "description"); d != nil {
			in.Description = d.Value
		}
		if r := child(spec, "required"); r != nil {
			in.Required = r.Value == "true"
		}
		if d := child(spec, "default"); d != nil && d.Kind == yaml.ScalarNode {
			in.Default = d.Value
		}
		if t := child(spec, "type"); t != nil && t.Value != "" {
			in.Type = t.Value
		}
		if o := child(spec, "options"); o != nil && o.Kind == yaml.SequenceNode {
			for _, v := range o.Content {
				in.Options = append(in.Options, fmt.Sprint(v.Value))
			}
		}
		info.Inputs = append(info.Inputs, in)
	}
	return info, nil
}

// child returns the value of key in a mapping node, or nil.
func child(m *yaml.Node, key string) *yaml.Node {
	if m == nil || m.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			return m.Content[i+1]
		}
	}
	return nil
}
