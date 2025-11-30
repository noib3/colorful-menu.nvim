local utils = require("colorful-menu.utils")
local Kind = require("colorful-menu").Kind
local insertTextFormat = require("colorful-menu").insertTextFormat
local config = require("colorful-menu").config

local M = {}

local function align_spaces(abbr, detail)
    if config.ls["rust-analyzer"].align_type_to_right == false then
        return " "
    end
    return utils.align_spaces_bell(abbr, detail)
end

local cashed_self_hl = nil
---@return CMHighlightRange[]
local function iter_chain()
    if cashed_self_hl == nil then
        local source = "fn iter(){}"
        local hl = utils.highlight_range(source, "rust-analyzer", 3, #source - 2)
        cashed_self_hl = hl.highlights
    end
    return cashed_self_hl
end

---@param completion_item lsp.CompletionItem
---@param ls string
---@return CMHighlights
local function _rust_analyzer(completion_item, ls)
    local label = completion_item.label
    local detail = completion_item.labelDetails and completion_item.labelDetails.detail or completion_item.detail
    local function_signature = completion_item.labelDetails and completion_item.labelDetails.description
        or completion_item.detail

    local kind = completion_item.kind
    if not kind then
        return utils.highlight_range(completion_item.label, ls, 0, #completion_item.label)
    end

    if kind == Kind.Field then
        -- Just highlight the field name, no type info
        local name = completion_item.label
        local source = string.format("struct S { %s: () }", name)
        local hl = utils.highlight_range(source, ls, 11, 11 + #name)
        return hl
        --
    elseif
        completion_item.insertTextFormat == insertTextFormat.Snippet
        and (label:find("::", nil, true) ~= nil or label == "Some(…)" or label == "None" or label == "Ok(…)" or label == "Err(…)")
        and label:sub(1, 1) >= "A"
        and label:sub(1, 1) <= "Z"
    then
        local source = string.format("match s { %s }", label)
        return utils.highlight_range(source, ls, 10, 10 + #label)
    elseif
        (kind == Kind.Constant or kind == Kind.Variable)
        and completion_item.insertTextFormat ~= insertTextFormat.Snippet
    then
        -- Just highlight the variable/constant name, no type info
        local name = completion_item.label
        local source = string.format("let %s = ();", name)
        local hl = utils.highlight_range(source, ls, 4, 4 + #name)
        if kind == Kind.Constant then
            -- Override highlight to use @constant
            for _, h in ipairs(hl.highlights) do
                if h[1]:find("variable") then
                    h[1] = utils.hl_exist_or("@constant", "@variable", "rust")
                end
            end
        end
        return hl
        --
    elseif kind == Kind.EnumMember then
        -- Just highlight the enum member name, no variant details
        local name = completion_item.label
        local source = string.format("enum S { %s }", name)
        return utils.highlight_range(source, ls, 9, 9 + #name)
        --
    elseif (kind == Kind.Function or kind == Kind.Method) and detail then
        -- Just highlight the label, optionally add ellipsis for args
        local current_label = label

        -- Ensure label has parentheses
        if not current_label:match("%(") then
            current_label = current_label .. "()"
        end

        -- Create simple function syntax for treesitter highlighting
        local source = string.format("fn %s {}", current_label)
        local hl = utils.highlight_range(source, ls, 3, 3 + #current_label)

        -- Check if function needs non-self arguments
        local needs_args = false
        if function_signature then
            local params_match = function_signature:match("%((.-)%)")
            if params_match then
                -- Remove self variations and check if anything remains
                local non_self = params_match:gsub("&?%s*mut%s+self%s*,?%s*", "")
                                             :gsub("&?%s*self%s*,?%s*", "")
                                             :gsub("^%s*", ""):gsub("%s*$", "")
                if non_self ~= "" then
                    needs_args = true
                end
            end
        end

        -- Insert ellipsis if args are needed and parens are empty
        if needs_args and current_label:match("%(%)") then
            local open_paren_pos = hl.text:find("%(")
            if open_paren_pos then
                -- Insert … (3 bytes in UTF-8)
                hl.text = hl.text:sub(1, open_paren_pos) .. "…" .. hl.text:sub(open_paren_pos + 1)
                -- Shift highlights that come after insertion
                for _, h in ipairs(hl.highlights) do
                    if h.range[1] >= open_paren_pos then
                        h.range = { h.range[1] + 3, h.range[2] + 3 }
                    elseif h.range[2] > open_paren_pos then
                        h.range = { h.range[1], h.range[2] + 3 }
                    end
                end
                -- Highlight the ellipsis
                table.insert(hl.highlights, { "@comment", range = { open_paren_pos, open_paren_pos + 3 } })
            end
        end

        -- Check for trait/import annotations in detail
        if detail then
            local trimmed = vim.trim(detail)
            local is_annotation = trimmed:match("^%(as .+%)") or trimmed:match("^%(use .+%)") or trimmed:match("^%(alias .+%)")
            if is_annotation then
                -- Store detail separately for blink.cmp to render in separate column
                hl.detail_text = trimmed
                hl.detail_highlights = {
                    {
                        "@comment",
                        range = { 0, #trimmed }
                    }
                }
            end
        end

        return hl
        --
    else
        local highlight_name = nil
        if kind == Kind.Struct then
            highlight_name = "@type"
        elseif kind == Kind.Enum then
            highlight_name = utils.hl_exist_or("@lsp.type.enum", "@type", "rust")
        elseif kind == Kind.EnumMember then
            highlight_name = utils.hl_exist_or("@lsp.type.enumMember", "@constant", "rust")
        elseif kind == Kind.Interface then
            highlight_name = utils.hl_exist_or("@lsp.type.interface", "@type", "rust")
        elseif kind == Kind.Function or kind == Kind.Method then
            highlight_name = "@function"
        elseif kind == Kind.Field then
            highlight_name = "@property"
        elseif kind == Kind.Variable then
            highlight_name = "@variable"
        elseif kind == Kind.Keyword then
            highlight_name = "@keyword"
        elseif kind == Kind.Value or kind == Kind.Constant then
            highlight_name = "@constant"
        else
            highlight_name = config.fallback_highlight
        end

        if detail then
            detail = vim.trim(detail)
            -- Only keep import/trait annotations like (use ...), (as ...), (alias ...)
            local is_import_annotation = detail:match("^%(use .+%)") or detail:match("^%(as .+%)") or detail:match("^%(alias .+%)")
            if is_import_annotation then
                return {
                    text = completion_item.label,
                    highlights = {
                        {
                            highlight_name,
                            range = { 0, #completion_item.label },
                        },
                    },
                    -- Store detail separately for blink.cmp
                    detail_text = detail,
                    detail_highlights = {
                        {
                            "@comment",
                            range = { 0, #detail }
                        }
                    },
                }
            end
        end

        return {
            text = completion_item.label,
            highlights = {
                {
                    highlight_name,
                    range = { 0, #completion_item.label },
                },
            },
        }
    end
end

---@param completion_item lsp.CompletionItem
---@param ls string
---@return CMHighlights
function M.rust_analyzer(completion_item, ls)
    local vim_item = _rust_analyzer(completion_item, ls)
    if vim_item.text ~= nil then
        -- Always highlight import/trait annotations with @comment
        for _, match in ipairs({ "%(use .-%)", "%(as .-%)", "%(alias .-%)" }) do
            local s, e = string.find(vim_item.text, match)
            if s ~= nil and e ~= nil then
                table.insert(vim_item.highlights, {
                    "@comment",
                    range = { s - 1, e },
                })
            end
        end
    end
    return vim_item
end

return M
