defmodule Excelixir do
  @moduledoc """
  Creates Excel XLSX files without external dependencies.
  Uses Office Open XML format with support for cell styling.
  """

  defmodule Style do
    @moduledoc """
    Represents cell styling options
    """
    defstruct [
      bold: false,
      italic: false,
      underline: false,
      font_size: 11,
      font_color: nil,
      background_color: nil
    ]

    def new(opts \\ []) do
      struct!(__MODULE__, opts)
    end
  end

  defmodule Cell do
    @moduledoc """
    Represents a cell with optional styling.
    """
    defstruct [:value, :style]

    @doc """
    Creates a new cell with the given value and optional style
    """
    def new(value, style_opts \\ []) do
      %__MODULE__{
        value: value,
        style: if(Enum.empty?(style_opts), do: nil, else: Style.new(style_opts))
      }
    end
  end

  @content_types """
  <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
  <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
  </Types>
  """

  @workbook_rels """
  <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
  <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
  </Relationships>
  """

  @workbook """
  <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
  <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets>
      <sheet name="Sheet1" sheetId="1" r:id="rId1"/>
    </sheets>
  </workbook>
  """

  @rels """
  <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
  <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
  </Relationships>
  """

  def create_excel(filename, rows) do
    {worksheet_xml, unique_styles} = generate_worksheet_xml(rows)
    styles_xml = generate_styles_xml(unique_styles)

    files = [
      {~c"[Content_Types].xml", @content_types},
      {~c"_rels/.rels", @rels},
      {~c"xl/workbook.xml", @workbook},
      {~c"xl/_rels/workbook.xml.rels", @workbook_rels},
      {~c"xl/worksheets/sheet1.xml", worksheet_xml},
      {~c"xl/styles.xml", styles_xml}
    ]

    :zip.create(String.to_charlist(filename), files)
  end

  defp extract_unique_styles(rows) do
    rows
    |> List.flatten()
    |> Enum.filter(&(match?(%Cell{style: %Style{}}, &1)))
    |> Enum.map(& &1.style)
    |> Enum.uniq()
  end

  defp generate_style_index_map(unique_styles) do
    unique_styles
    |> Enum.with_index(1)
    |> Map.new()
  end

  defp generate_worksheet_xml(rows) do
    unique_styles = extract_unique_styles(rows)
    style_index_map = generate_style_index_map(unique_styles)

    rows_xml =
      rows
      |> Enum.with_index(1)
      |> Enum.map(&generate_row_xml(&1, style_index_map))
      |> Enum.join("\n")

    worksheet = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>
        #{rows_xml}
      </sheetData>
    </worksheet>
    """

    {worksheet, unique_styles}
  end

  defp generate_row_xml({row, row_num}, style_index_map) do
    cells =
      row
      |> Enum.with_index(?A)
      |> Enum.map(fn {value, col} ->
        cell_ref = "#{<<col>>}#{row_num}"
        generate_cell_xml(value, cell_ref, style_index_map)
      end)
      |> Enum.join("\n")

    """
      <row r="#{row_num}">
        #{cells}
      </row>
    """
  end

  defp generate_cell_xml(value, cell_ref, style_index_map) do
    case value do
      %Cell{value: value, style: %Style{} = style} ->
        {type, formatted_value} = format_cell_value(value)
        style_index = Map.get(style_index_map, style, 0)
        type_attr = if type != "", do: ~s( t="#{type}"), else: ""
        """
            <c r="#{cell_ref}"#{type_attr} s="#{style_index}">
              #{formatted_value}
            </c>
        """

      %Cell{value: value} ->
        {type, formatted_value} = format_cell_value(value)
        type_attr = if type != "", do: ~s( t="#{type}"), else: ""
        """
            <c r="#{cell_ref}"#{type_attr}>
              #{formatted_value}
            </c>
        """

      value ->
        {type, formatted_value} = format_cell_value(value)
        type_attr = if type != "", do: ~s( t="#{type}"), else: ""
        """
            <c r="#{cell_ref}"#{type_attr}>
              #{formatted_value}
            </c>
        """
    end
  end

  defp format_cell_value(value) do
    case value do
      "=" <> formula -> {"", "<f>#{escape_xml(formula)}</f>"}
      v when is_number(v) -> {"n", "<v>#{v}</v>"}
      v when is_binary(v) -> {"inlineStr", "<is><t>#{escape_xml(v)}</t></is>"}
      v -> {"inlineStr", "<is><t>#{escape_xml("#{v}")}</t></is>"}
    end
  end

  defp generate_styles_xml(unique_styles) do
    style_count = length(unique_styles)
    font_definitions = generate_font_definitions(unique_styles)
    fill_definitions = generate_fill_definitions(unique_styles)
    cell_xfs = generate_cell_xfs(unique_styles)

    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fonts count="#{style_count + 1}">
        <font>
          <sz val="11"/>
          <name val="Calibri"/>
          <family val="2"/>
        </font>
        #{font_definitions}
      </fonts>
      <fills count="#{style_count + 2}">
        <fill>
          <patternFill patternType="none"/>
        </fill>
        <fill>
          <patternFill patternType="gray125"/>
        </fill>
        #{fill_definitions}
      </fills>
      <borders count="1">
        <border/>
      </borders>
      <cellStyleXfs count="1">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
      </cellStyleXfs>
      <cellXfs count="#{style_count + 1}">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        #{cell_xfs}
      </cellXfs>
    </styleSheet>
    """
  end

  defp generate_font_definitions(styles) do
    styles
    |> Enum.map(fn style ->
      bold = if style.bold, do: "<b/>", else: ""
      italic = if style.italic, do: "<i/>", else: ""
      underline = if style.underline, do: "<u/>", else: ""
      color = if style.font_color, do: ~s(<color rgb="#{style.font_color}"/>), else: ""

      """
        <font>
          #{bold}
          #{italic}
          #{underline}
          #{color}
          <sz val="#{style.font_size}"/>
          <name val="Calibri"/>
          <family val="2"/>
        </font>
      """
    end)
    |> Enum.join("\n")
  end

  defp generate_fill_definitions(styles) do
    styles
    |> Enum.map(fn style ->
      case style.background_color do
        nil ->
          """
            <fill>
              <patternFill patternType="none"/>
            </fill>
          """

        color ->
          """
            <fill>
              <patternFill patternType="solid">
                <fgColor rgb="#{color}"/>
              </patternFill>
            </fill>
          """
      end
    end)
    |> Enum.join("\n")
  end

  defp generate_cell_xfs(styles) do
    styles
    |> Enum.with_index(1)
    |> Enum.map(fn {style, index} ->
      font_id = index
      fill_id = if style.background_color, do: index + 1, else: 0

      """
        <xf numFmtId="0" fontId="#{font_id}" fillId="#{fill_id}" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
      """
    end)
    |> Enum.join("\n")
  end

  defp escape_xml(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
