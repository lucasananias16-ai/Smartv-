# Smartv-: acelerar e limpar a Android TV

`tv-tune.sh` deixa sua Android TV / Google TV mais rápida e limpa a tela inicial, pelo adb.
Ele **pergunta antes de mudar qualquer coisa**, **nunca desinstala nada** e cria **um comando que desfaz tudo**.

---

## Passo a passo

### Passo 1: preparar a TV

1. **Ligue as Opções do desenvolvedor** (se ainda não estiverem ligadas):
   Configurações > Sistema > Sobre > clique **7 vezes** em "Build do Android TV OS" (ou "Versão").
2. **Ligue a depuração:** Configurações > Sistema > Opções do desenvolvedor > **Depuração USB** = ligada.
   Se aparecer também **"Depuração ADB pela rede"** ou **"Depuração de rede"** (comum em Xiaomi e TCL), ligue também.
3. **Anote o IP da TV** (caso o programa não ache a TV sozinho):
   Configurações > Rede e Internet > clique na sua rede Wi-Fi > "Endereço IP" (algo como `192.168.0.25`).
4. Deixe a TV **ligada** e na mesma rede Wi-Fi do computador.

### Passo 2: baixar o programa no computador

1. Abra o repositório no GitHub: **github.com/lucasananias16-ai/Smartv-**
2. Troque o branch (botão do canto superior esquerdo, que mostra `main`) para **`claude/kind-clarke-stzwal`**.
3. Clique em **`tv-tune.sh`** e depois no botão de **download** (ícone de seta, "Download raw file").
4. O arquivo vai para a pasta **Downloads**.

### Passo 3: abrir o terminal

- **Windows:** instale o **Git for Windows** em https://git-scm.com (pode deixar tudo no padrão). Depois abra o programa **Git Bash** no menu Iniciar.
- **Mac:** abra o app **Terminal** (Cmd + Espaço, digite "Terminal").
- **Linux:** abra o **Terminal**.

### Passo 4: rodar

No terminal, digite os dois comandos abaixo, um de cada vez, apertando Enter:

```bash
cd ~/Downloads
```

```bash
bash tv-tune.sh
```

Se o adb não estiver instalado, o programa instala sozinho (no Mac pode pedir o Homebrew; no Linux, sua senha).

### Passo 5: responder às perguntas

O programa vai mostrando cada etapa. Em perguntas **[S/n]**, aperte Enter para "sim"; em **[s/N]**, Enter quer dizer "não".

1. **Procurando sua TV:** se achar mais de uma, digite o número da sua. Se não achar nenhuma, digite o IP que você anotou.
2. **Aperte "Permitir" na TV** quando aparecer a janela (marque "Sempre permitir").
3. **Reiniciar antes?** Responda **S**. Assim a comparação de memória fica justa.
4. **Quais apps você usa?** Digite os números separados por espaço (ex.: `2 5 6`). Os que você não digitar entram na lista "pode desativar".
5. **Tabela:** mostra tudo em NECESSÁRIO / MEU / PODE DESATIVAR. Nada foi mudado ainda.
6. **Lista para desativar:** digite os números que você quer **manter**, ou só Enter para aprovar todos.
7. **Perguntas extras:**
   - Busca por voz: desligar faz o botão do microfone e a busca pararem.
   - Chromecast: desligar impede transmitir do celular.
   - Protetor de tela, ligar direto na TV ao vivo, animações, tela inicial nova sem anúncios.
8. **"Aplicar?"**: só aqui as mudanças são feitas. Responda **s** para aplicar.

No final, a TV reinicia e aparece a tabela **memória antes x depois**.

### Passo 6: arrumar a tela inicial nova (se escolheu instalar)

Com o controle, no FLauncher:
1. Segure OK num app > categorias: crie uma fileira **"Meus apps"** com seus apps.
2. Crie a fileira **"Entradas e configurações"** com o app de Entradas da TV e Configurações.
3. Engrenagem (canto superior direito) > ligue o **relógio** e escolha um fundo simples.

---

## Como desfazer tudo

O programa mostra no final o comando exato, parecido com:

```bash
bash ~/tv-tune/undo-20261109-203000.sh
```

Ele reativa tudo, restaura as configurações antigas e reinicia a TV.
Os registros ficam na pasta `tv-tune`, dentro da sua pasta de usuário:
- `audit-*.txt`: a tabela de apps
- `changes-*.log`: cada mudança feita (e o comando de desfazer em uma linha)
- `undo-*.sh`: o script que desfaz tudo

## Problemas comuns

| Problema | O que fazer |
|---|---|
| "Nenhuma TV encontrada" | Digite o IP da TV quando o programa pedir. |
| A janela "Permitir" não aparece | Confira a Depuração USB / Depuração de rede (Passo 1). Desligue e ligue a TV e rode de novo. |
| A TV ainda liga na TV ao vivo | É uma opção do fabricante. Sony: Configurações > Sistema > Energia > Comportamento ao ligar. Philips/TCL/Hisense: Configurações > Entradas ou Energia > Entrada ao ligar. |
| O botão Home abre a tela antiga | Rode de novo e responda "s" para desativar a tela inicial original (dá para desfazer). |
| No Windows: "adb não encontrado" depois de instalar | Feche e abra o Git Bash e rode de novo. |

## Opções avançadas

| Variável | Para quê |
|---|---|
| `TVTUNE_TARGET=192.168.0.25` | Pula a busca e usa este IP |
| `TVTUNE_SETTLE=90` | Segundos de espera após ligar, antes de medir a memória |

Exemplo:

```bash
TVTUNE_TARGET=192.168.0.25 bash tv-tune.sh
```
