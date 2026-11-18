package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"

	"petcare-backend/config"
	"petcare-backend/handlers"
)

// newTestRouter cria o roteador com um cliente MongoDB "preguiçoso"
// (nenhuma conexão é aberta até uma operação real), suficiente para testar
// validação de entrada, rotas e health checks sem banco de dados.
func newTestRouter(t *testing.T, ping PingFunc) http.Handler {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	client, err := mongo.Connect(ctx, options.Client().ApplyURI("mongodb://127.0.0.1:1").
		SetServerSelectionTimeout(200*time.Millisecond))
	if err != nil {
		t.Fatalf("mongo.Connect: %v", err)
	}
	t.Cleanup(func() { _ = client.Disconnect(context.Background()) })

	cfg := &config.Config{MongoDatabase: "petcare_test"}
	h := handlers.New(client.Database(cfg.MongoDatabase), &config.AWSClients{}, cfg)
	return NewRouter(h, ping, "test-sha")
}

func do(t *testing.T, r http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func okPing(context.Context) error   { return nil }
func failPing(context.Context) error { return errors.New("down") }

func TestHealthLiveness(t *testing.T) {
	w := do(t, newTestRouter(t, okPing), http.MethodGet, "/health", "")
	if w.Code != http.StatusOK {
		t.Fatalf("esperado 200, obtido %d", w.Code)
	}
	var body map[string]string
	_ = json.Unmarshal(w.Body.Bytes(), &body)
	if body["version"] != "test-sha" {
		t.Fatalf("versão incorreta: %v", body)
	}
}

func TestHealthReadiness(t *testing.T) {
	if w := do(t, newTestRouter(t, okPing), http.MethodGet, "/health/ready", ""); w.Code != http.StatusOK {
		t.Fatalf("banco ok: esperado 200, obtido %d", w.Code)
	}
	if w := do(t, newTestRouter(t, failPing), http.MethodGet, "/health/ready", ""); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("banco fora: esperado 503, obtido %d", w.Code)
	}
}

func TestSecurityHeaders(t *testing.T) {
	w := do(t, newTestRouter(t, okPing), http.MethodGet, "/health", "")
	for _, h := range []string{"X-Content-Type-Options", "X-Frame-Options"} {
		if w.Header().Get(h) == "" {
			t.Errorf("cabeçalho de segurança ausente: %s", h)
		}
	}
}

func TestListServicos(t *testing.T) {
	w := do(t, newTestRouter(t, okPing), http.MethodGet, "/api/servicos", "")
	if w.Code != http.StatusOK {
		t.Fatalf("esperado 200, obtido %d", w.Code)
	}
	var servicos []map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &servicos); err != nil {
		t.Fatalf("JSON inválido: %v", err)
	}
	if len(servicos) == 0 {
		t.Fatal("lista de serviços vazia")
	}
}

func TestValidacaoEntrada(t *testing.T) {
	r := newTestRouter(t, okPing)
	casos := []struct {
		nome, metodo, rota, corpo string
		esperado                  int
	}{
		{"pet sem campos obrigatórios", http.MethodPost, "/api/pets", `{"raca":"srd"}`, http.StatusBadRequest},
		{"pet com JSON malformado", http.MethodPost, "/api/pets", `{"nome":`, http.StatusBadRequest},
		{"cliente sem email", http.MethodPost, "/api/clientes", `{"nome":"Ana"}`, http.StatusBadRequest},
		{"agendamento sem serviço", http.MethodPost, "/api/agendamentos", `{}`, http.StatusBadRequest},
		{"pet com ID inválido", http.MethodGet, "/api/pets/nao-e-objectid", "", http.StatusBadRequest},
		{"status com ID inválido", http.MethodPut, "/api/agendamentos/xyz/status", `{"status":"concluido"}`, http.StatusBadRequest},
		{"status desconhecido", http.MethodPut, "/api/agendamentos/507f1f77bcf86cd799439011/status", `{"status":"hackeado"}`, http.StatusBadRequest},
		{"injeção NoSQL no status", http.MethodPut, "/api/agendamentos/507f1f77bcf86cd799439011/status", `{"status":{"$ne":""}}`, http.StatusBadRequest},
	}
	for _, c := range casos {
		t.Run(c.nome, func(t *testing.T) {
			if w := do(t, r, c.metodo, c.rota, c.corpo); w.Code != c.esperado {
				t.Fatalf("esperado %d, obtido %d (%s)", c.esperado, w.Code, w.Body.String())
			}
		})
	}
}

func TestRotaInexistente(t *testing.T) {
	if w := do(t, newTestRouter(t, okPing), http.MethodGet, "/api/admin", ""); w.Code != http.StatusNotFound {
		t.Fatalf("esperado 404, obtido %d", w.Code)
	}
}
