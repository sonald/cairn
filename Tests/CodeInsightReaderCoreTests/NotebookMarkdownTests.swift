import CodeInsightReaderCore
import Foundation
import Testing

@Test
func notebookCellsBecomeMarkdownThatCellTextCannotBreak() throws {
    let notebook = """
    {"nbformat": 4, "metadata": {"kernelspec": {"language": "python"}},
     "cells": [
      {"cell_type": "markdown", "source": "---\\ntitle: x\\n---"},
      {"cell_type": "code", "source": ["s = '```'\\n", "print(s)"], "outputs": [
        {"output_type": "stream", "text": ["\\u001b[1m10%\\r\\u001b[1ma\\u001b[0m\\r\\n", "\\n", "b\\n"]},
        {"output_type": "error", "traceback": ["\\u001b[0;31mValueError\\u001b[0m: bad"]},
        {"output_type": "display_data", "data": {"image/png": "iVBO\\nRw==", "text/plain": "<Figure>"}}
      ]}
     ]}
    """
    let markdown = try #require(NotebookMarkdown.markdown(fromNotebook: Data(notebook.utf8)))
    #expect(markdown == """

    ---
    title: x
    ---

    ````python
    s = '```'
    print(s)
    ````

    > ```
    > a
    >
    > b
    > ```

    > ```
    > ValueError: bad
    > ```

    > ![](data:image/png;base64,iVBORw==)
    """)
    #expect(NotebookMarkdown.markdown(fromNotebook: Data("{\"a\": 1}".utf8)) == nil)
    #expect(NotebookMarkdown.markdown(fromNotebook: Data("not json".utf8)) == nil)
}
