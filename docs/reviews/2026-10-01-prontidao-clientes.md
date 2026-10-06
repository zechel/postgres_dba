# Revisão do postgres_dba para uso em clientes

Data: 2026-10-01. Base revisada: `a69ef51b6cd63c2fa6598f25707e4dbbb1a314e6`.

A versão revisada já está publicada em [zechel/postgres_dba](https://github.com/zechel/postgres_dba). O commit local, `origin/master` e o commit de `master` consultado pela API do GitHub coincidem. O [CI desse commit](https://github.com/zechel/postgres_dba/actions/runs/32990922183), executado em 2026-08-26, passou nos cinco jobs de PostgreSQL 14, 15, 16, 17 e 18.

Os testes de execução SQL estão funcionando, mas não verificam suficientemente a correção das recomendações de índices e excluem as rotinas interativas de usuários. Esta revisão reproduziu problemas nessas áreas. Recomendo corrigir os achados P1 antes de distribuir o conjunto completo como ferramenta para clientes. A existência de CI verde não elimina esses problemas.

Esta entrega é uma análise: nenhum SQL, script do produto, workflow ou README foi alterado; nenhum commit ou push foi realizado. Os achados permanecem pendentes.

## Achados prioritários

### F01 — P1: `i5` gera sugestões de DROP que podem remover garantias de unicidade

Arquivo: [sql/i5_indexes_migration.sql](../../sql/i5_indexes_migration.sql), linhas 60–98.

O relatório escolhe `i2` como candidato à remoção, mas compara suas colunas com o prefixo de `i1` na direção errada. As verificações de unicidade também protegem o índice de referência em vez de garantir que o candidato possa ser removido com segurança.

Reproduções em tabelas sintéticas:

- Com índices `(a)` e `(a,b)`, o relatório declarou `(a,b)` redundante em relação a `(a)`.
- Com um índice comum `(a)` e um índice `UNIQUE(a)`, sugeriu remover o índice único. Executei somente esse DROP na tabela sintética e uma inserção duplicada passou a ser aceita: havia duas linhas com `a = 1`.
- A comparação textual de `indkey` confundiu a coluna de posição `1` com a coluna de posição `10`, classificando índices sobre colunas distintas como redundantes.

O script imprime DDL; não executa os DROPs. O impacto ocorre quando o operador aplica a migração sugerida.

Correção necessária: comparar sequências de atributos com limites explícitos, corrigir a direção da cobertura e preservar unicidade, constraints e diferenças semânticas dos índices. A geração de DDL deve ter testes que validem o efeito das sugestões, além do sucesso da consulta.

### F02 — P1: `u2` mantém SUPERUSER e LOGIN quando o operador responde “não”

Arquivo: [roles/alter_user_with_random_password.psql](../../roles/alter_user_with_random_password.psql), linhas 49–58.

O ramo negativo gera `ALTER ROLE nome` sem `NOSUPERUSER` ou `NOLOGIN`. A operação retorna sucesso, troca a senha e mantém os atributos anteriores.

Reprodução: criei `audit_role SUPERUSER LOGIN`, executei a rotina com respostas `0` e `0` e consultei `pg_roles`. O resultado permaneceu `rolsuper = true` e `rolcanlogin = true`.

Correção necessária: emitir explicitamente ambos os valores possíveis dos atributos e validar o estado final. Os atributos negativos estão documentados em [ALTER ROLE](https://www.postgresql.org/docs/18/sql-alterrole.html).

### F03 — P1: respostas inválidas podem conceder SUPERUSER

Arquivos: [roles/create_user_with_random_password.psql](../../roles/create_user_with_random_password.psql), linhas 48–49, e [roles/alter_user_with_random_password.psql](../../roles/alter_user_with_random_password.psql), linhas 51 e 56.

Qualquer resposta que não pertença à pequena lista de respostas negativas é tratada como afirmativa. Isso inclui erros de digitação e respostas negativas em português.

Reprodução: respondi `nao` à pergunta de SUPERUSER em `u1`. A rotina terminou com sucesso e criou uma role com `rolsuper = true`.

Correção necessária: aceitar um conjunto explícito de respostas afirmativas e negativas e rejeitar valores desconhecidos antes de modificar a role. A afirmação sobre concessão de privilégio deve ser verificada nos testes.

### F04 — P1: geração e exibição de senhas contradizem a promessa de segurança

Arquivos: ambas as rotinas de [roles/](../../roles/), linhas 39–53 em criação e 39–59 em alteração; [misc/generate_password.sql](../../misc/generate_password.sql); seção “Secure Role Management” do [README](../../README.md).

As senhas usam `random()`. Duas sessões com a mesma chamada `setseed(0.125)` geraram exatamente a mesma senha de 16 caracteres para duas roles diferentes. Os valores das senhas foram mantidos somente em memória durante a comparação e não constam deste relatório nem dos resultados JSON. A [documentação de PostgreSQL](https://www.postgresql.org/docs/18/functions-math.html) explica que esse gerador não serve para aplicações criptográficas; [pgcrypto](https://www.postgresql.org/docs/18/pgcrypto.html) oferece geração criptográfica de bytes.

Além disso, `RAISE DEBUG` inclui SQL com a senha e `RAISE INFO` inclui a senha em texto claro. No teste com `log_min_messages = info`, confirmei que a senha gerada apareceu no log do servidor. Isso depende da configuração de logging; não significa que toda instalação com o padrão `warning` registre a mensagem INFO. A documentação descreve esse controle em [Errors and Messages](https://www.postgresql.org/docs/18/plpgsql-errors-and-messages.html).

Correção necessária: usar uma fonte criptográfica, eliminar senhas das mensagens do servidor e revisar a forma de entrega da senha ao cliente e a documentação. A ausência em logs precisa ser testada nas configurações que serão suportadas.

### F05 — P1: `i2` e `i3` confundem índices com semânticas diferentes

Arquivos: [sql/i2_redundant_indexes.sql](../../sql/i2_redundant_indexes.sql), linhas 76–86, e [sql/i3_duplicate_indexes.sql](../../sql/i3_duplicate_indexes.sql), linhas 10–12.

Reproduções:

- `i2` classificou `UNIQUE(a)` como redundante em relação a `PRIMARY KEY(a,b)`. A chave composta permite valores repetidos de `a`; portanto, não substitui a garantia de `UNIQUE(a)`.
- `i3` agrupou um índice comum e um índice único sobre a mesma coluna como duplicados.
- `i2` e `i3` trataram `(a ASC,b ASC)` e `(a ASC,b DESC)` como equivalentes, embora atendam ordenações diferentes.

Esses relatórios são consultas de diagnóstico. O risco está em usar a classificação como fundamento suficiente para remover índices.

Correção necessária: considerar a semântica de unicidade, ordenação, collation, tratamento de NULLs e atributos chave/INCLUDE, além de método de acesso, expressões e predicados. Testar os casos reproduzidos junto da correção de `i5`.

## Outros achados reproduzidos

### F06 — P2: entradas são interpoladas sem escape SQL

Arquivos: [start.psql](../../start.psql), linha 46; [init/generate.sh](../../init/generate.sh), linha 94; ambas as rotinas de roles, linhas 16–25; [sql/a2_queries_runing_n_seconds.sql](../../sql/a2_queries_runing_n_seconds.sql), linha 15; `k1` e `k2`, linha 5.

Montar aspas por concatenação de variáveis não escapa apóstrofos. Um nome de role válido com apóstrofo produziu erro de sintaxe. No menu completo, uma entrada contendo apóstrofo e uma instrução SELECT adicional executou essa instrução no banco descartável. O teste usou somente SELECT com um marcador inofensivo.

Não se trata de uma escalada remota de privilégio demonstrada: o operador já possui uma sessão SQL com seus próprios privilégios. O problema é a execução inesperada de texto inserido em um campo do menu e a fragilidade dos parâmetros.

Correção necessária: usar a sintaxe de escape de literais do psql, validar valores numéricos antes de chamar funções administrativas e aplicar a correção no gerador que produz `start.psql`.

### F07 — P2: o gerador pode sobrescrever arquivos no diretório do chamador

Arquivo: [init/generate.sh](../../init/generate.sh), linhas 8–11.

O script esvazia `warmup.psql` e `start.psql` antes de entrar na raiz do repositório. Em uma cópia temporária, executei o script de outro diretório que continha arquivos com esses nomes: ambos foram esvaziados e o comando terminou com código zero.

Executado da raiz, o gerador produziu arquivos idênticos aos rastreados. O problema depende do diretório de execução.

Correção necessária: resolver os caminhos de saída antes de escrever, falhar em caso de erro e preferir escrita temporária seguida de substituição. Testar a preservação de arquivos no diretório do chamador.

### F08 — P2: `a2` mostra duração negativa

Arquivo: [sql/a2_queries_runing_n_seconds.sql](../../sql/a2_queries_runing_n_seconds.sql), linhas 9 e 16.

`age(query_start, clock_timestamp())` calcula a diferença na direção inversa. Uma sessão sintética executando `pg_sleep(2)` apareceu com duração negativa.

Correção necessária: exibir `clock_timestamp() - query_start`, com nome explícito para a coluna e ordenação consistente com a duração desejada.

## Verificações realizadas

- [x] Comparei HEAD local, referência `origin/master` e commit publicado pela API do GitHub.
- [x] Consultei os resultados individuais dos cinco jobs PostgreSQL 14–18 no CI do commit revisado.
- [x] Li os arquivos rastreados do produto e a configuração de testes: 55 arquivos, aproximadamente 4.642 linhas.
- [x] Executei os 33 relatórios automatizados em quatro combinações no PostgreSQL 18.6: superuser/pg_monitor × modo normal/wide. Foram 132 execuções com `ON_ERROR_STOP=1`, sem falhas.
- [x] Validei nove cenários de regressão: node, alignment, atividade, unidade de parâmetro, FK sem/com intarray e ausência de extensões em s1, s2 e b6. Todos passaram.
- [x] Executei `b6` com limiar zero para medir tabelas reais da fixture, incluindo relações com e sem TOAST, como `pg_monitor`. Passou. O limiar padrão de 100 MB não mede essas tabelas pequenas no smoke test normal.
- [x] Reproduzi os problemas de atributos de roles, senha, logging, recomendações de índices, entrada do menu, diretório de geração e duração.
- [x] Testei `p1` durante CREATE INDEX CONCURRENTLY em outro banco: a consulta retornou com sucesso. A suspeita de erro fatal nesse cenário não se confirmou e não é um achado bloqueante desta revisão.
- [x] Validei a sintaxe Bash do gerador, a reprodução de `start.psql`/`warmup.psql` e a classificação completa dos 39 relatórios: 33 automatizados e seis excluídos.
- [x] Executei `git diff --check`: sem problemas nos arquivos rastreados.
- [x] Busquei padrões de chaves privadas, tokens GitHub, access keys AWS e URLs com credenciais nos 55 arquivos atuais e nos 566 blobs alcançáveis pelos 424 commits de HEAD: nenhum padrão encontrado. A busca por padrões não equivale a uma auditoria completa de todos os tipos de segredo.
- [x] Tentei `npm run lint`, `npm run typecheck`, `npm test` e `npm run build`: todos retornaram ENOENT porque a raiz não possui `package.json`. Esses gates genéricos do AGENTS.md não estão implementados neste projeto SQL/psql; não foram considerados aprovados.

Os testes novos foram executados em um contêiner PostgreSQL descartável, sem rede, sem portas expostas e sem volumes de clientes. O Docker Desktop não estava disponível; usei Podman com uma imagem PostgreSQL 18 já existente. A validação local desta revisão cobriu PostgreSQL 18; a evidência para 14–17 vem do CI existente. Não foram executados testes em infraestrutura de clientes, réplicas reais, RDS ou bancos com cargas representativas de produção.

Não executei CodeRabbit; não foi identificada sua instalação no PATH desta sessão. Este relatório não substitui um gate formal de QA nem afirma que todos os gates AIOX passaram.

## Publicação e arquivos locais

Antes desta revisão, havia 1.759 arquivos não rastreados em pastas de agentes/framework e artefatos locais, incluindo `.agents/`, `.aiox-core/`, `.claude/`, `.codex/`, `.grok/`, `.kimi/`, `.cursor/rules/agents/`, `.env.example`, `AGENTS.md` e uma pasta de recursos de uma página salva do GitHub. Não são commits pendentes de produto.

Esses arquivos não foram incluídos nem removidos. Para uma publicação de correções, preparar o staging com os arquivos explicitamente revisados e conferir o diff staged. Um `git add .` também adicionaria material local fora do escopo da ferramenta.

O campo `services.postgres.command` do workflow foi conferido na [documentação atual de GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idservicesservice_idcommand). Ele é suportado e o CI publicado o executou com sucesso. Não recomendo modificá-lo com base na suspeita inicial desta revisão.

## Critérios para a próxima entrega aos clientes

- [ ] Corrigir e testar F01/F05: preservar unicidade, cobertura de índices e diferenças de ordenação.
- [ ] Corrigir e testar F02/F03: aplicar atributos negativos e rejeitar respostas desconhecidas.
- [ ] Corrigir e testar F04: gerar senhas com fonte criptográfica e remover exposição em mensagens do servidor.
- [ ] Corrigir F06–F08 e acrescentar verificações específicas dos comportamentos reproduzidos.
- [ ] Executar novamente a matriz PostgreSQL 14–18 com os testes de comportamento das correções.
- [ ] Documentar o perfil de diagnóstico com `pg_monitor`, as permissões necessárias e as operações que mudam estado ou fazem scans extensos.
- [ ] Vincular as correções a stories com critérios de aceitação e file list, conforme as instruções do repositório.
- [ ] Preparar commit/PR somente com os arquivos de produto e evidências que forem revisados para publicação.

Até as correções, `u1` e `u2` não devem ser usados para gerenciar contas em clientes. As saídas de `i2`, `i3` e `i5` não devem ser tratadas como validação suficiente para remover índices. A compatibilidade de execução dos demais relatórios tem a evidência de CI e dos testes descritos acima; custo, acesso a informações e configuração de cada cliente ainda precisam ser considerados na operação.

## Arquivos desta entrega

- `docs/reviews/2026-10-01-prontidao-clientes.md`: este relatório.
- `docs/reviews/2026-10-01-prontidao-clientes.resultados.json`: resultados estruturados das reproduções, sem senhas ou logs do servidor.

Os scripts exploratórios permaneceram em `/tmp/postgres_dba_review_20261001.py`, `/tmp/postgres_dba_review_followup_20261001.py` e `/tmp/postgres_dba_review_index_edges_20261001.py`. Nenhum desses scripts foi incorporado ao produto.
