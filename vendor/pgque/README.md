# PgQue (vendorizado)

Este diretório contém uma cópia vendorizada do [PgQue](https://pgque.dev) — fila
de eventos "zero-bloat" para PostgreSQL, implementada inteiramente em SQL e
PL/pgSQL, licença Apache-2.0.

- **Por que vendorizado**: PgQue não é distribuído via CPAN/cpanfile (não é um
  módulo Perl) — é um pacote SQL de terceiros. Vendorizar uma cópia pinada evita
  dependência de rede no build da imagem Docker/CI e mantém a versão auditada
  (ver [ADR-022](https://github.com/Hibex-Solutions/crystallized-perl/blob/main/docs/adrs/ADR-022-filas-em-postgresql.md))
  sob controle deste repositório.
- **Tag/commit/checksums atuais**: `SOURCE.json` neste diretório — nunca edite
  esse arquivo à mão, ele é reescrito por `eng/pgque_vendor.pl update`.
- **Instalação em `db-events`**: `eng/bootstrap_pgque.pl` executa `pgque.sql`
  (idempotente).
- **`LICENSE`/`NOTICE`**: também vendorizados a partir da mesma tag — a
  Apache-2.0 exige redistribuir o conteúdo do `NOTICE` junto do código.

## Verificando e atualizando

`eng/pgque_vendor.pl` é a única ferramenta que fala com o GitHub do PgQue
(`github.com/NikolayS/PgQue`) — nunca roda no build da imagem nem em produção,
só localmente por um desenvolvedor:

```bash
# Tag/commit/checksums vendorizados atualmente + checagem de integridade local
carton exec perl eng/pgque_vendor.pl status
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl status | Out-Host

# Tags disponíveis no GitHub (marca a atual)
carton exec perl eng/pgque_vendor.pl list
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl list | Out-Host

# Atualiza para outra tag (baixa pgque.sql + LICENSE + NOTICE, reescreve SOURCE.json)
carton exec perl eng/pgque_vendor.pl update v0.3.0
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl update v0.3.0 | Out-Host

# Compara o pgque.sql local contra uma tag do GitHub (git diff --no-index)
carton exec perl eng/pgque_vendor.pl diff v0.3.0
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl diff v0.3.0 | Out-Host

# Sem tag: compara contra a própria tag gravada em SOURCE.json — valida que o
# arquivo local não foi corrompido/editado à mão desde o download
carton exec perl eng/pgque_vendor.pl diff
# Windows/PowerShell: carton exec perl eng/pgque_vendor.pl diff | Out-Host
```

> **Windows/PowerShell**: encadeie `| Out-Host` em qualquer um dos comandos
> acima (`carton exec` não tem `exec()` real no Windows — a saída aparece
> atrasada/dessincronizada sem isso) e rode, uma vez por sessão de terminal,
> **antes** do primeiro comando:
> ```powershell
> [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; chcp 65001 | Out-Null
> ```
> Sem isso, `| Out-Host` corrige a sincronia mas corrompe os acentos/símbolos
> que `status`/`diff` imprimem (`✔`, `⚠`, "não", "é"). Detalhes completos em
> [DEVELOPMENT.md](../../DEVELOPMENT.md#1-visão-geral-do-ambiente).

Ao atualizar a versão, revisar `docs/upgrading.md` do PgQue para mudanças de
API que quebrem compatibilidade — a própria v0.2.0 renomeou argumentos
públicos em relação à v0.1.0.
