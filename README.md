# godot-authoritative-dice

Demo em Godot 4 de rolagem de dados em rede, do jeito que uma mesa virtual de RPG precisa. São dois modos, lado a lado, para mostrar uma regra só: **o cliente envia intenção, nunca resultado**.

## O problema

Se o dado é rolado na máquina do jogador e o servidor apenas repassa o número, o jogador escolhe o resultado. Não é preciso nada sofisticado: basta um cliente modificado que mande "12" toda vez.

```
VULNERÁVEL                              AUTORITATIVO

cliente              servidor           cliente              servidor
   │  "tirei [6, 6]"    │                  │  "quero rolar 2d6" │
   │ ─────────────────► │                  │ ─────────────────► │
   │                    │ repassa          │                    │ valida o pedido
   │                    │ sem checar       │                    │ rola o dado
   │ ◄───────────────── │                  │ ◄───────────────── │
   │   [6, 6] para todos                   │   [3, 5] para todos
```

O mesmo princípio vale fora de jogos: um carrinho de compras em que o navegador envia o preço tem exatamente esta falha.

## Como rodar

Requer Godot 4.3 ou superior.

1. Abra a pasta do projeto no Godot (Importar → selecione `project.godot`).
2. Em **Depurar → Personalizar Instâncias de Execução**, ative múltiplas instâncias e escolha 2.
3. Rode o projeto (F5). Abrem duas janelas.
4. Em uma, clique em **Hospedar**. Na outra, em **Entrar**.

## O que testar

| Passo | Modo (escolhido por quem hospeda) | No cliente | Resultado esperado |
| --- | --- | --- | --- |
| 1 | Vulnerável | Rolar | Resultado aleatório, marcado como "informado pelo cliente" |
| 2 | Vulnerável | Marcar **Trapacear** e rolar | `[6, 6] = 12` todas as vezes. O servidor aceita. |
| 3 | Autoritativo | Rolar | Resultado aleatório, marcado como "rolado pelo servidor" |
| 4 | Autoritativo | Marcar **Trapacear** e rolar | `RECUSADO`, visível para todos na mesa |

O passo 2 contra o passo 4 é a demonstração.

## Onde está cada coisa

Tudo em `scripts/main.gd`:

| Função | Roda em | Papel |
| --- | --- | --- |
| `submit_result(rolls)` | servidor | Caminho vulnerável: recebe o resultado pronto. No modo autoritativo, recusa. |
| `request_roll(count, sides)` | servidor | Caminho seguro: valida quantidade e tipo de dado, limita a frequência e rola. |
| `_sender_id()` | servidor | Identifica quem chamou pelo transporte, e não por um parâmetro do cliente. |
| `announce_roll(...)` | todos | Só o servidor pode chamar (`@rpc("authority")`). |
| `sync_mode(...)` | clientes | O modo é do servidor; o cliente só é informado. |

## Modelo de ameaças

O que o modo autoritativo barra:

- Cliente enviando um resultado fabricado.
- Cliente pedindo uma rolagem fora das regras (`99d1000`, quantidade negativa).
- Cliente rolando em nome de outro jogador.
- Cliente fingindo ser o servidor para anunciar um resultado.
- Enxurrada de pedidos de um mesmo jogador.

O que ele não cobre:

- Quem hospeda é o servidor. Num jogo em que um dos jogadores hospeda, esse jogador ainda pode trapacear; a solução para isso é um servidor dedicado.
- Tráfego sem criptografia nem autenticação de jogador. Qualquer um na rede local entra.
- A conexão é fixa em `127.0.0.1`, só para a demo.

## Próximos passos

- [ ] GIF comparando os dois modos.
- [ ] Save assinado com HMAC, para detectar edição manual do arquivo.
- [ ] Servidor dedicado em modo headless.

## Licença

MIT.
