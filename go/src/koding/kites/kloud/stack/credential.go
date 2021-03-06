package stack

import (
	"context"
	"encoding/json"
	"errors"

	"koding/kites/kloud/credential"
	"koding/kites/kloud/utils/object"

	"github.com/koding/kite"
)

// CredentialDescribeRequest represents a request
// value for "credential.describe" kloud method.
type CredentialDescribeRequest struct {
	Provider string `json:"provider,omitempty"`
	Template []byte `json:"template,omitempty"`
}

// CredentialDescribeResponse represents a response
// value from "credential.describe" kloud method.
type CredentialDescribeResponse struct {
	Description map[string]*Description `json:"description"`
}

// Description describes Credential and Bootstrap
// types used by a given provider.
type Description struct {
	Provider   string  `json:"provider,omitempty"`
	Credential []Value `json:"credential"`
	Bootstrap  []Value `json:"bootstrap,omitempty"`
}

// Enumer represents a value, that can have
// a limited set of values.
//
// It is used to create drop-down lists
// or suggest possible value to the user.
type Enumer interface {
	Enums() []Enum
}

// Enum is a description of a single enum value.
type Enum struct {
	Title string      `json:"title,omitempty"`
	Value interface{} `json:"value"`
}

// Value represents a description of a single
// field within Bootstrap or Credential struct.
type Value struct {
	Name     string `json:"name"`
	Type     string `json:"type"`
	Label    string `json:"label"`
	Secret   bool   `json:"secret"`
	ReadOnly bool   `json:"readOnly"`
	Values   []Enum `json:"values,omitempty"`
}

// CredentialListRequest represents a request
// value for "credential.list" kloud method.
type CredentialListRequest struct {
	Provider string `json:"provider,omitempty"`
	Team     string `json:"team,omitempty"`
	Template []byte `json:"template,omitempty"`

	Impersonate string `json:"impersonate"`
}

// CredentialItem represents a single credential
// metadata.
type CredentialItem struct {
	Title      string `json:"title"`
	Team       string `json:"team,omitempty"`
	Identifier string `json:"identifier"`
}

// CredentialListResponse represents a response
// value for "credential.list" kloud method.
type CredentialListResponse struct {
	Credentials map[string][]CredentialItem `json:"credentials"`
}

// CredentialAddRequest represents a request
// value for "credential.add" kloud method.
type CredentialAddRequest struct {
	Provider string          `json:"provider"`
	Team     string          `json:"team,omitempty"`
	Title    string          `json:"title,omitempty"`
	Data     json.RawMessage `json:"data"`

	Impersonate string `json:"impersonate"`
}

// CredentialAddResponse represents a response
// value for "credential.add" kloud method.
type CredentialAddResponse struct {
	Title      string `json:"title"`
	Identifier string `json:"identifier"`
}

// CredentialDescribe is a kite.Handler for "credential.describe" kite method.
func (k *Kloud) CredentialDescribe(r *kite.Request) (interface{}, error) {
	var req CredentialDescribeRequest

	if err := r.Args.One().Unmarshal(&req); err != nil {
		return nil, err
	}

	// TODO: add support for reading the provider names by parsing
	// the req.Template.

	desc := k.DescribeFunc(req.Provider)

	if len(desc) == 0 {
		return nil, errors.New("no provider found")
	}

	return &CredentialDescribeResponse{
		Description: desc,
	}, nil
}

// CredentialList is a kite.Handler for "credential.list" kite method.
func (k *Kloud) CredentialList(r *kite.Request) (interface{}, error) {
	var req CredentialListRequest

	if err := r.Args.One().Unmarshal(&req); err != nil {
		return nil, err
	}

	if IsKloudctlAuth(r, k.SecretKey) {
		// kloudctl is not authenticated with username, let it overwrite it
		r.Username = req.Impersonate
	}

	f := &credential.Filter{
		Username: r.Username,
		Teamname: req.Team,
		Provider: req.Provider,
	}

	creds, err := k.CredClient.Creds(f)
	if err != nil {
		return nil, err
	}

	resp := &CredentialListResponse{
		Credentials: make(map[string][]CredentialItem),
	}

	for _, cred := range creds {
		c := resp.Credentials[cred.Provider]

		c = append(c, CredentialItem{
			Title:      cred.Title,
			Team:       cred.Team,
			Identifier: cred.Ident,
		})

		resp.Credentials[cred.Provider] = c
	}

	return resp, nil
}

// CredentialAdd is a kite.Handler for "credential.add" kite method.
func (k *Kloud) CredentialAdd(r *kite.Request) (interface{}, error) {
	var req CredentialAddRequest

	if err := r.Args.One().Unmarshal(&req); err != nil {
		return nil, err
	}

	if req.Provider == "" {
		return nil, NewError(ErrProviderIsMissing)
	}

	if len(req.Data) == 0 {
		return nil, NewError(ErrCredentialIsMissing)
	}

	if IsKloudctlAuth(r, k.SecretKey) {
		r.Username = req.Impersonate
	}

	p, ok := k.providers[req.Provider]
	if !ok {
		return nil, NewError(ErrProviderNotFound)
	}

	c := &credential.Cred{
		Provider: req.Provider,
		Title:    req.Title,
		Team:     req.Team,
	}

	cred := p.NewCredential()
	boot := p.NewBootstrap()

	if boot != nil {
		c.Data = object.Inline(cred, boot)
	} else {
		c.Data = cred
	}

	if err := json.Unmarshal(req.Data, c.Data); err != nil {
		return nil, err
	}

	if v, ok := cred.(Validator); ok {
		if err := v.Valid(); err != nil {
			return nil, err
		}
	}

	if err := k.CredClient.SetCred(r.Username, c); err != nil {
		return nil, err
	}

	teamReq := &TeamRequest{
		Provider:   req.Provider,
		GroupName:  req.Team,
		Identifier: c.Ident,
	}

	kiteReq := &kite.Request{
		Method:   "bootstrap",
		Username: r.Username,
	}

	s, ctx, err := k.NewStack(p, kiteReq, teamReq)
	if err != nil {
		return nil, err
	}

	bootReq := &BootstrapRequest{
		Provider:    req.Provider,
		Identifiers: []string{c.Ident},
		GroupName:   req.Team,
	}

	ctx = context.WithValue(ctx, BootstrapRequestKey, bootReq)

	credential := &Credential{
		Provider:   c.Provider,
		Title:      c.Title,
		Identifier: c.Ident,
		Credential: cred,
		Bootstrap:  boot,
	}

	if err := s.VerifyCredential(credential); err != nil {
		return nil, err
	}

	if _, err := s.HandleBootstrap(ctx); err != nil {
		return nil, err
	}

	return &CredentialAddResponse{
		Title:      c.Title,
		Identifier: c.Ident,
	}, nil
}
