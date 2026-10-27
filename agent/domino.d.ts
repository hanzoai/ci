// The one function of domino (turndown's own HTML parser) this tool calls. The
// package's own declaration names the module 'domino' and exports nothing.
declare module '@mixmark-io/domino' {
  const domino: { createDocument(html?: string, force?: boolean): Document };
  export default domino;
}
