import { describe, expect, test } from 'bun:test';
import { docLineCount, docReadOf, isDocPath } from './doc-read';

describe('docReadOf', () => {
  test('a Read of a Markdown file is a doc read, its folder shortened', () => {
    expect(
      docReadOf({
        name: 'Read',
        input: { file_path: '/home/u/worktrees/run-1/docs/code-maps/clean-code.md' },
      })
    ).toEqual({
      path: '/home/u/worktrees/run-1/docs/code-maps/clean-code.md',
      file: 'clean-code.md',
      dir: '…/run-1/docs/code-maps',
      range: null,
    });
  });

  test('names the part read', () => {
    const read = (input: Record<string, unknown>) =>
      docReadOf({ name: 'Read', input: { file_path: 'docs/memory.md', ...input } })?.range;
    expect(read({ offset: 40, limit: 80 })).toBe('lines 40–119');
    expect(read({ offset: 40 })).toBe('from line 40');
    expect(read({ limit: 80 })).toBe('first 80 lines');
  });

  test('a short path keeps its folder whole', () => {
    expect(docReadOf({ name: 'Read', input: { file_path: 'docs/memory.md' } })?.dir).toBe('docs');
    expect(docReadOf({ name: 'Read', input: { file_path: 'README.md' } })?.dir).toBe('');
  });

  test('a code file, a search or another tool is not a doc read', () => {
    expect(docReadOf({ name: 'Read', input: { file_path: 'src/app.ts' } })).toBeNull();
    expect(docReadOf({ name: 'Grep', input: { path: 'docs/', pattern: 'x' } })).toBeNull();
    expect(docReadOf({ name: 'Edit', input: { file_path: 'docs/memory.md' } })).toBeNull();
    expect(docReadOf({ name: 'Read', input: {} })).toBeNull();
  });
});

describe('isDocPath', () => {
  test('prose files and anything under a docs folder', () => {
    expect(isDocPath('CLAUDE.md')).toBe(true);
    expect(isDocPath('guide.MDX')).toBe(true);
    expect(isDocPath('notes.txt')).toBe(true);
    expect(isDocPath('docs/code-maps/x.map.json')).toBe(true);
    expect(isDocPath('C:\\repo\\docs\\a.json')).toBe(true);
    expect(isDocPath('src/docs.ts')).toBe(false);
  });
});

describe('docLineCount', () => {
  test('counts the lines answered, ignoring the trailing newline', () => {
    expect(docLineCount('     1\t# A\n     2\tb\n')).toBe(2);
    expect(docLineCount('')).toBeNull();
    expect(docLineCount(undefined)).toBeNull();
  });
});
