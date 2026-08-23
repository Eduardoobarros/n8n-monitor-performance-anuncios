# Monitor de Performance de Anúncios — n8n

Automação que recebe as métricas de um anúncio, calcula os indicadores de
eficiência e dispara alerta quando o ROAS fica abaixo da meta. Construída em n8n,
com histórico persistido em PostgreSQL.

**Problema que resolve:** times de mídia paga perdem tempo revisando manualmente
métricas de anúncios pra identificar quais estão com performance ruim. Esse
workflow automatiza a detecção e guarda o histórico para análise posterior.

---

## Como funciona

- Recebe métricas via webhook (`anuncio`, `gasto`, `faturamento`, `vendas_qtd`, `cliques`, `impressoes`)
- Valida os campos obrigatórios antes de calcular qualquer coisa
- Calcula CTR, ROAS, CPA e ticket médio
- Sinaliza alerta quando o ROAS fica abaixo da meta (padrão 3x)
- Quando há alerta, informa **quanto falta** de faturamento e a quantas vendas isso equivale
- Retorna diagnóstico estruturado e grava a linha em `anuncios_monitorados`

## Os 9 nós, na ordem

```
Receber Dados do Anuncio (Webhook)
        │
Validar Dados do Anuncio (IF) ──[false]──▶ Responder Dados Invalidos      400
        │
Calcular ROAS e CPA (Code)
        │
ROAS Abaixo do Minimo? (IF)
        ├──[true]───▶ Montar Alerta de Performance (Set) ─┐
        └──[false]──▶ Montar Status Saudavel (Set) ───────┤
                                                          ▼
                                             Responder ao Sistema         200
                                                          │
                                             Gravar no Postgres
```

## Cálculos exatos

Todos no nó `Calcular ROAS e CPA`:

| Métrica | Fórmula | Observação |
|---|---|---|
| `roas` | `faturamento ÷ gasto` | 0 se não houve gasto |
| `ctr` | `(cliques ÷ impressoes) × 100` | `null` se não vierem impressões |
| `cpa` | `gasto ÷ vendas_qtd` | custo por aquisição |
| `ticket_medio` | `faturamento ÷ vendas_qtd` | |
| `resultado` | `faturamento − gasto` | negativo = prejuízo |
| `taxa_conversao` | `(vendas_qtd ÷ cliques) × 100` | `null` se não vierem cliques |
| `gap_faturamento` | `max(gasto × roas_minimo − faturamento, 0)` | quanto falta pra meta |
| `vendas_faltantes` | `ceil(gap_faturamento ÷ ticket_medio)` | traduz o gap em vendas |
| `classificacao` | `saudavel` ≥ meta · `atencao` ≥ 1x · `critico` < 1x | |

## Decisões técnicas

- **Nó Code em vez de expressões inline.** São nove métricas com divisões que
  precisam de guarda contra zero. Espalhar isso em expressões dentro de nós Set
  deixaria a lógica ilegível e sem lugar para comentar o porquê.

- **Meta de ROAS configurável, não hardcoded.** Vem em `roas_minimo` no payload e
  cai em `3` como padrão. Cada categoria de produto tem margem diferente — fixar
  no código obrigaria a duplicar o workflow por categoria.

- **Classificação em três níveis, alerta binário.** `critico` (ROAS < 1x, o
  anúncio dá prejuízo direto) é diferente de `atencao` (ROAS entre 1x e a meta,
  paga o custo mas não entrega margem). Os dois disparam alerta, mas o banco
  guarda a distinção para análise depois.

- **CTR vira `null`, não zero, quando faltam impressões.** Zero afirmaria que
  ninguém clicou; `null` diz que não dá pra saber. A coluna é nullable de
  propósito, e uma média futura não fica contaminada por zeros falsos.

- **Os dois ramos convergem num único nó de resposta**, que devolve o objeto
  inteiro com um campo booleano `alerta`. Quem consome o webhook decide o que
  fazer sem precisar interpretar texto.

- **O nó Postgres vem depois do `Respond to Webhook`.** O nó Postgres substitui o
  `$json` da saída — se viesse antes, a resposta HTTP sairia com `{id, criado_em}`
  em vez do diagnóstico. `Respond to Webhook` envia a resposta mas não encerra a
  execução, então a gravação acontece logo em seguida. O custo: se o INSERT
  falhar, quem chamou já recebeu 200 — a falha fica visível na lista de execuções
  do n8n, não para o cliente.

- **Parâmetros SQL posicionais (`$1, $2, $3, $4`), não concatenação.** O driver
  envia comando e valores separados, o que elimina SQL injection — mesmo
  princípio do `PreparedStatement`. E são passados como **array**, não como lista
  separada por vírgula: a lista quebraria se um nome de produto contivesse vírgula.

---

## Exemplo

**Requisição**

```http
POST http://localhost:5678/webhook/monitor-anuncio
Content-Type: application/json

{
  "anuncio": "Fone Bluetooth TWS",
  "gasto": 1240.00,
  "faturamento": 768.50,
  "vendas_qtd": 9,
  "cliques": 413,
  "impressoes": 28400
}
```

`anuncio`, `cliques`, `impressoes` e `roas_minimo` são opcionais. Os obrigatórios
são `gasto`, `faturamento` e `vendas_qtd`.

**Resposta — ROAS abaixo da meta**

```
🔴 ALERTA — PERFORMANCE ABAIXO DO MÍNIMO
Fone Bluetooth TWS · 22/08/2026 21:09

INVESTIMENTO x RETORNO
Gasto .......... R$ 1.240,00
Faturamento .... R$ 768,50
Resultado ...... -R$ 471,50
ROAS ........... 0.62x  (mínimo: 3x)

OPERAÇÃO
Vendas ......... 9
CPA ............ R$ 137,78
Ticket médio ... R$ 85,39

Faltam R$ 2.951,50 de faturamento para atingir o ROAS mínimo — cerca de 35 vendas no ticket atual.
Ação sugerida: revisar segmentação e criativo, ou pausar o anúncio.
```

**Resposta — ROAS saudável**

```
🟢 ANÚNCIO DENTRO DA META
Kit Organizador de Gavetas · 22/08/2026 21:09

INVESTIMENTO x RETORNO
Gasto .......... R$ 480,00
Faturamento .... R$ 2.136,90
Resultado ...... R$ 1.656,90
ROAS ........... 4.45x  (mínimo: 3x)

OPERAÇÃO
Vendas ......... 31
CPA ............ R$ 15,48
Ticket médio ... R$ 68,93

Nenhuma ação necessária.
```

![Execução no n8n](assets/print-monitor.png)

---

## Persistência

O resultado de cada monitoramento vira uma linha em `anuncios_monitorados`
(schema em [`sql/schema.sql`](sql/schema.sql)).

**Decisão:** valores monetários e percentuais em `NUMERIC`, nunca em ponto
flutuante. Binário não representa `0,10` exatamente e o erro acumula a cada
operação — o mesmo motivo pelo qual se usa `BigDecimal` em vez de `double` no Java.

Estado após a bateria de testes:

```
 id |          produto           | ctr  | roas |  status
----+----------------------------+------+------+----------
  1 | Fone Bluetooth TWS         | 1.45 | 0.62 | critico
  2 | Suporte Veicular Magnetico | 2.00 | 2.20 | atencao
  3 | Kit Organizador de Gavetas | 3.01 | 4.45 | saudavel
```

![Banco](assets/print-banco.png)

---

## Stack

| Camada | Tecnologia |
|---|---|
| Orquestração | n8n 2.35.7 |
| Gatilho | Webhook (POST, modo `responseNode`) |
| Lógica | Nó Code (JavaScript) · nó IF com operadores de número |
| Persistência | PostgreSQL 17 em Docker, SQL parametrizado |
| Testes | Coleção Postman com asserções automáticas |

---

## Como rodar localmente

**1. Subir o banco**

```bash
docker run -d --name n8n-postgres \
  -e POSTGRES_USER=n8n_dev \
  -e POSTGRES_PASSWORD=dev_local_123 \
  -e POSTGRES_DB=n8n_dados \
  -p 5433:5432 \
  -v n8n_pgdata:/var/lib/postgresql/data \
  postgres:17-alpine

docker exec -i n8n-postgres psql -U n8n_dev -d n8n_dados < sql/schema.sql
```

Credenciais descartáveis, de desenvolvimento local. A porta do host é **5433**
porque a 5432 já estava ocupada por outra instalação do PostgreSQL na máquina —
dentro do container o serviço continua na 5432.

**2. Importar o workflow**

No n8n: **Workflows → ⋯ → Import from File** → `workflow/monitor-performance-anuncios.json`

**3. Criar a credencial**

**Settings → Credentials → New → Postgres**, apontando para `localhost:5433`,
banco `n8n_dados`, usuário `n8n_dev`. Depois, associar ao nó `Gravar no Postgres`.

**4. Ativar e testar**

O workflow precisa estar **ativo** — webhook de produção não responde com o
workflow desligado.

Importe [`postman/monitor-anuncios.postman_collection.json`](postman/) no Postman.
São 4 requisições com asserções automáticas: ROAS baixo, ROAS saudável, payload
inválido e um caso sem impressões que demonstra o CTR virando `null`.

---

## Testes

| Cenário | Esperado | Resultado |
|---|---|---|
| ROAS 0.62x (abaixo de 1x) | `200`, `alerta: true`, `critico` | ✅ |
| ROAS 2.20x (entre 1x e a meta) | `200`, `alerta: true`, `atencao` | ✅ |
| ROAS 4.45x (acima da meta) | `200`, `alerta: false`, `saudavel` | ✅ |
| Sem `faturamento` | `400`, `status: invalido` | ✅ |
| Sem `impressoes` | `200`, `ctr: null` | ✅ |

Todos os ramos condicionais foram percorridos e conferidos nó a nó pelo histórico
de execuções do n8n.
