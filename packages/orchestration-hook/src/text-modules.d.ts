// Bun inlines a `with { type: "text" }` import as a string at build time.
// TypeScript needs the shape declared; the payload bodies are the only such
// imports in this package.
declare module "*.tmpl" {
  const content: string;
  export default content;
}
