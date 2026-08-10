# Guia do GitHub — passo a passo (sem programar, sem terminal)

Este guia é para quem **nunca programou** e **não usa terminal**. O objetivo é simples:
colocar o projeto no GitHub para que um robô do próprio GitHub **compile o código
sozinho** e diga se está tudo certo. Você só vai usar o navegador e o mouse.

Vai levar uns 15 minutos. Siga na ordem.

---

## Parte 1 — Criar uma conta grátis no GitHub

1. Abra o site **https://github.com** no navegador.
2. Clique em **Sign up** (Cadastrar), no canto superior direito.
3. Digite seu e-mail, crie uma senha e escolha um nome de usuário.
   - Anote a senha em lugar seguro.
4. Confirme o código que o GitHub enviar para o seu e-mail.
5. Quando ele perguntar o plano, escolha o **Free** (grátis). É suficiente.

Pronto, você tem uma conta.

---

## Parte 2 — Criar o repositório (o "lugar" do projeto)

Um repositório é como uma pasta na nuvem que guarda o projeto.

1. Já logado, clique no **+** no canto superior direito e depois em **New repository**
   (Novo repositório).
2. Em **Repository name** (nome), escreva por exemplo: `caderno-app`.
3. Em visibilidade, deixe marcado **Public** (Público).
   - **Importante:** este repositório é só de **código**. **Nunca** coloque aqui suas
     anotações, cadernos ou arquivos pessoais. Só entram os arquivos do projeto.
4. **Não** marque nenhuma das caixinhas de "Add a README", ".gitignore" ou "license" —
   o projeto já tem esses arquivos.
5. Clique em **Create repository** (Criar repositório).

---

## Parte 3 — Subir os arquivos arrastando pelo site

Você vai levar os arquivos do projeto para o repositório arrastando com o mouse.

1. Na página do repositório recém-criado, clique em **Add file** (Adicionar arquivo) e
   depois em **Upload files** (Enviar arquivos).
2. Abra no seu computador a pasta do projeto (a pasta `BonfimBook`).
3. **Selecione tudo que está dentro dela** e arraste para a área do navegador que diz
   "Drag files here" (Arraste os arquivos aqui).

   > **Atenção à pasta `.github`** (o nome começa com um ponto). Ela é **essencial** —
   > é ela que faz o robô compilar o código automaticamente. Pastas que começam com ponto
   > às vezes ficam escondidas. Se ela não subir junto, o robô não vai rodar.
   >
   > **Se a `.github` não aparecer:** no Windows, abra a pasta `BonfimBook`, vá em
   > **Exibir → Mostrar → Itens ocultos** e arraste a `.github` também. No Mac, aperte
   > **Cmd + Shift + . (ponto)** para revelar itens ocultos e arraste.
   >
   > Você pode arrastar as pastas inteiras — o GitHub sobe tudo o que estiver dentro.

4. Espere as barrinhas de envio terminarem.
5. Mais abaixo, no campo de mensagem, pode deixar o texto que já vem preenchido.
6. Clique no botão verde **Commit changes** (Confirmar alterações).

Os arquivos agora estão no GitHub.

---

## Parte 4 — Ver o resultado da compilação automática

Assim que os arquivos sobem, o robô do GitHub começa a compilar o código sozinho.

1. Na página do repositório, clique na aba **Actions** (fica na barra de cima, ao lado de
   "Code").
2. Você verá uma linha com o nome do último envio. Ao lado dela há um símbolo:
   - 🟡 **bolinha amarela girando** = ainda está compilando, espere um ou dois minutos.
   - ✅ **✓ verde** = **deu tudo certo**, o código compilou e passou nos testes.
   - ❌ **✗ vermelho** = **deu erro** em alguma parte.
3. **Se aparecer o ✗ vermelho:** clique em cima dele, depois clique no passo que estiver
   marcado em vermelho para abrir os detalhes. Tire um **print (captura de tela)** dessa
   parte vermelha e **me mande** — com o print eu descubro e corrijo o problema.

Você não precisa entender o texto do erro. Só me mandar a imagem já basta.

---

## Parte 5 — Baixar o app para o iPad depois

Quando quiser levar o app para o iPad:

1. No iPad, instale o app grátis **Swift Playgrounds** pela App Store.
2. No navegador do iPad, abra a página do seu repositório no GitHub.
3. Clique no botão verde **Code** e depois em **Download ZIP**. Isso baixa o projeto
   inteiro compactado.
4. Abra o arquivo baixado no app **Arquivos** do iPad e descompacte (toque nele).
5. Entre na pasta e localize **`BonfimBook.swiftpm`**. Toque nela.
6. O **Swift Playgrounds** abre o projeto automaticamente. Toque em **Executar** (▶) para
   rodar o BonfimBook no seu iPad.

Só a pasta `BonfimBook.swiftpm` é o app; o resto (testes, configurações) fica no iPad sem
atrapalhar e pode ser ignorado.

---

### Resumo de segurança

- Repositório **público** = qualquer um vê o **código**. Por isso: **só código**, nunca
  suas anotações ou arquivos pessoais.
- Em caso de dúvida sobre o que subir, suba apenas o que veio na pasta `BonfimBook` do
  projeto. Nada de arquivos seus.
