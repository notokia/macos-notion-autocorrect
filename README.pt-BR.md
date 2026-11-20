# NotionAutocorrect (macOS · Multi-idioma)

🌎 **Idioma:** [English](README.md) | Português (Brasil)

Aplicativo nativo para macOS (Objective-C · `AppKit` + `ApplicationServices`) que traz **autocorreção automática em tempo real** ao digitar dentro do **Notion Desktop (`Notion.app`)**, funcionando **100% offline** e **pronto para usar sem configuração**.

---

## O Problema

O aplicativo Desktop do Notion para macOS é construído sobre **Electron (Chromium)**. Diferente de aplicativos nativos em Cocoa (`NSTextView`), o Electron no macOS não aciona a substituição automática nativa do sistema (`NSSpellChecker`) enquanto você digita — oferecendo apenas sublinhado vermelho para correção manual com clique direito.

## Recursos (Ready-to-Use)

- **🌐 Detecção Automática de Idioma:** Lê o idioma configurado no seu Notion e no seu macOS e detecta automaticamente em tempo real se você está digitando em **Português (BR/PT), Inglês (US/UK), Espanhol, Francês, Alemão ou Italiano** (com opção de fixar um idioma no painel).
- **☁️ Sincronizado com os Atalhos do Mac / iCloud:** Importa automaticamente todas as **Substituições de Texto do macOS** (*Ajustes do Sistema → Teclado → Substituição de Texto*).
- **🍎 Motor Oficial da Apple (`NSSpellChecker`):** Corrige erros de digitação e falta de acentos usando os dicionários nativos offline do macOS (< 1 ms, sem enviar nenhum dado para fora do Mac).
- **🚫 Desfazer com 1 Backspace + Lista Visível de Palavras Ignoradas:** Apertou espaço e não queria aquela correção? Pressione `Backspace` uma vez para restaurar a palavra original — ela entra automaticamente na lista visível de **Palavras Ignoradas** (botão **🚫 Palavras Ignoradas** no painel), onde você pode consultar, adicionar ou restaurar qualquer palavra.
- **🧩 Proteção Especial para o Notion:** Substitui apenas o sufixo diferente (nunca junta blocos no início da linha), ignora `/comandos`, `@menções`, `` `código` ``, links/e-mails (`google.com.br`), acentos digitados manualmente e siglas em maiúsculas (`USP`, `PIB`, `TCC`).
- **⚙️ Iniciar com o Mac & Interface no Idioma do Sistema:** Painel nativo traduzido automaticamente para o idioma do macOS (PT/EN/ES/FR), com opção de **Iniciar automaticamente ao ligar o Mac** em 1 clique.

---

## Como Instalar

### Opção 1 — Instalador `.dmg` Universal (Apple Silicon + Intel)
Tudo já vai embutido no `.dmg` — sem precisar instalar nada por fora:
1. Baixe o arquivo **`NotionAutocorrect.dmg`** na aba [Releases](../../releases).
2. Abra o `.dmg` e arraste o **NotionAutocorrect.app** para a pasta **Aplicativos**.
3. Na primeira vez que abrir, clique com o **botão direito → Abrir** e ative a chave em **Ajustes do Sistema → Privacidade e Segurança → Acessibilidade**.

### Opção 2 — Instalação em 1 linha no Terminal
```bash
curl -fsSL https://raw.githubusercontent.com/notokia/macos-notion-autocorrect/main/install.sh | zsh
```

### Opção 3 — Compilar do código-fonte
Requer macOS 13.0+ e Xcode Command Line Tools (`xcode-select --install`):
```bash
git clone https://github.com/notokia/macos-notion-autocorrect.git
cd macos-notion-autocorrect
./build.sh
open -a /Applications/NotionAutocorrect.app
```

Para gerar o instalador `.dmg` em `dist/NotionAutocorrect.dmg`:
```bash
./package_dmg.sh
```

---

## Apoie o Projeto

Se o **NotionAutocorrect** economiza o seu tempo no dia a dia, deixe uma ⭐ **Star** no repositório ou pague um café para apoiar o projeto!

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/notokia)

> *Aviso: Este é um utilitário independente e de código aberto feito para usuários do Notion, sem vínculo oficial com a Notion Labs, Inc.*

---

## Licença

Distribuído sob a licença [MIT](LICENSE).
