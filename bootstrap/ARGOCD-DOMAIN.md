# Argo CD: Domínio Público vs Acesso Local

## Resumo

**Não é necessário** ter um domínio público para o Argo CD funcionar. Ele funciona perfeitamente sem domínio público, mas há algumas diferenças:

## Funcionalidades que NÃO precisam de domínio público

✅ **Sync automático via polling** - O Argo CD verifica o repositório periodicamente (a cada 3 minutos por padrão)
✅ **Acesso à UI via port-forward** - Você pode acessar via `kubectl port-forward`
✅ **Todas as funcionalidades básicas** - Criar apps, fazer sync manual, gerenciar recursos
✅ **Acesso a repositórios privados** - Funciona com SSH keys ou tokens

## Funcionalidades que PRECISAM de domínio público

⚠️ **Webhooks do GitHub** - Para sync imediato quando há push (sem polling delay)
⚠️ **Acesso à UI sem port-forward** - Acesso direto via navegador
⚠️ **Integrações externas** - Serviços que precisam chamar a API do Argo CD

## Comparação

| Funcionalidade | Sem Domínio Público | Com Domínio Público |
|---------------|---------------------|---------------------|
| Sync automático | ✅ Sim (polling a cada 3min) | ✅ Sim (webhook imediato) |
| Acesso à UI | ✅ Via port-forward | ✅ Direto no navegador |
| Repositórios privados | ✅ Sim | ✅ Sim |
| Webhooks GitHub | ❌ Não | ✅ Sim |
| Todas funcionalidades | ✅ Sim | ✅ Sim |

## Recomendação

Para um servidor pessoal/homelab:
- **Sem domínio público**: Funciona perfeitamente, sync a cada 3 minutos
- **Com domínio público**: Sync imediato via webhooks, acesso mais conveniente

**Conclusão**: Domínio público é um "nice to have", não um requisito.
