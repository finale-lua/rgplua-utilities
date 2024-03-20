function plugindef()
    -- This function and the 'finaleplugin' namespace
    -- are both reserved for the plug-in definition.
    finaleplugin.RequireDocument = false
    finaleplugin.NoStore = true
    finaleplugin.HandlesUndo = true
    finaleplugin.MinJWLuaVersion = 0.72
    finaleplugin.Author = "Robert Patterson"
    finaleplugin.Copyright = "CC0 https://creativecommons.org/publicdomain/zero/1.0/"
    finaleplugin.Version = "1.5.1"
    finaleplugin.Date = "March 20, 2024"
    finaleplugin.Notes = [[
        If you want to execute scripts running in Trusted mode, this console script must also be
        configured as Trusted in the RGP Lua Configuration window.
    ]]
    return "RGP Lua Console...", "RGP Lua Console", "Allows immediate execution and editing of scripts in RGP Lua."
end

local cjson = require('cjson')
local lfs = require("lfs")
local osutils = require("luaosutils")
local text = osutils.text

-- Keep configured_script_items at the top level so that it exists as long as the script runs.
-- This guarantees that browser_script_item does not get destroyed.
local configured_script_items = finenv.CreateLuaScriptItems()
local browser_script_item = (function()
    for item in each(configured_script_items) do
        if item.FileName == "rgpluaclassbrowser.lua" then
            return item
        end
    end
    return nil
end)()

local function win_mac(winval, macval)
    if finenv.UI():IsOnWindows() then return winval end
    return macval
end

--local variables with script-wide scope: reset each time the script is run

local file_menu             -- file menu
local file_menu_cursel = -1 -- needed because Windows calls our on_popop routine more than just for selections
local in_popup_handler      -- needed to avoid churn when we change the selected item inside the popup handler
local script_menu           -- script menu
local edit_text             -- text editor
local line_number_text      -- line mumbers
local output_text           -- print output area
local clear_output_chk      -- Clear Before Run checkbox
local run_as_trusted_chk    -- Run As Trusted checkbox
local run_as_debug_chk      -- Run As Debug checkbox
local line_ending_show      -- Static control to show line endings
local run_script_cmd        -- run script command
local kill_script_cmd       -- kill running script command
local hires_timer           -- For timing scripts
local in_scroll_handler     -- needed to prevent infinite scroll handler loop
local in_text_change_event  -- needed to prevent infinite text_change handleer loop
local in_execute_script_item      -- tracks is we are inside on_run_script
local find_requested        -- used by Windows to trigger the Find dialog box
local in_timer              -- used to prevent timer reentrancy
local modal_depth = 0       -- used to count modal depth of scripts

--global variables that persist (thru Lua garbage collection) until the script releases its Lua State

global_timer_id = 1         -- per docs, we supply the timer id, starting at 1

if not finenv.RetainLuaState then
    config =
    {
        tabstop_width = 4,
        tabs_to_spaces = true,
        output_tabstop_width = 8,
        clear_output_before_run = false,
        word_wrap = false,
        output_wrap = true,
        run_as_trusted = false,
        run_as_debug = false,
        show_timestamps = false,
        font_name = win_mac("Consolas", "Menlo"),
        font_size = win_mac(9, 11),
        font_advance_points = win_mac(4.9482421875, 6.62255859375), -- win 10pt Consolas is 5.498046875
        total_width = 960,
        editor_height = 280,
        editor_line_spacing = win_mac(0, 4.0);
        output_console_height = 130,
        curr_script_item = 0,
        search_regex = false,
        search_ignore_case = false,
        search_whole_words = false,
        search_currsel = false,
        window_pos_valid = false,
        window_pos_x = 0, -- must be non-nil so config reader captures it
        window_pos_y = 0, -- must be non-nil so config reader captures it
        recent_files = {}
    }
    context =
    {
        script_text = nil,          -- holds current contents of edit box when our window is not open
        original_script_text = "",  -- used to check if the text has been modified
        modification_time = nil,    -- used to check if the file has been modified
        output_text = nil,          -- holds current contents of output box when our window is not open
        script_items_list = {},     -- each member is a table of 'items' (script items) and 'exists' (boolean)
        selected_script_item = 0,   -- 1-based Lua index into script_items_list
        line_numbers = {},
        line_ending_type = 0,       -- tracks the line ending type (used in Windows only)
        file_menu_base = { "< New >", "< Open... >", "< Save >", "< Save As... >", "< Close >", "-", "< Close All >", "-" },
        first_script_in_menu = 8,
        untitled_counter = 1,
        working_directory = (function()     -- this gets modified as we go
            local str = finale.FCString()
            str:SetUserPath()
            if #str.LuaString <= 0 then
                return finenv.RunningLuaFolderPath()
            end
            return str.LuaString
        end)(),
        working_directory_valid = false,
        search_pattern = nil
    }
end

local function encode_file_path(file_path)
    if text.get_default_codepage() ~=  text.get_utf8_codepage() then
        return text.convert_encoding(file_path, text.get_utf8_codepage(), text.get_default_codepage())
    end
    return file_path
end

local function config_filepath()
    local fcstr = finale.FCString()
    fcstr:SetUserOptionsPath()
    fcstr:AssureEndingPathDelimiter()
    return fcstr.LuaString .. "com.robertgpatterson.rgpluaconsole.json"
end

local function config_read()
    local file <close> = io.open(encode_file_path(config_filepath()), "r")
    if file then
        local json_text = file:read("a")
        local json = cjson.decode(json_text)
        local function table_to_config(jt, ct)
            if type(jt) == "table" then
                for k, v in pairs(jt) do
                    if ct[k] == nil or type(v) == type(ct[k]) then
                        if type(v) ~= "table" then
                            ct[k] = v
                        else
                            table_to_config(v, ct[k])
                        end
                    end
                end
            end
        end
        table_to_config(json, config)
    end
end

local function config_write()
    local file <close> = io.open(encode_file_path(config_filepath()), "w")
    if file then
        local json_text = cjson.encode(config)
        if json_text and #json_text > 0 then
            file:write(prettyformatjson(json_text, 4))
        end
    end
end

local LINE_ENDINGS_DOS = 1
local LINE_ENDINGS_MAC = 2
local LINE_ENDINGS_UNIX = 3
local LINE_ENDINGS_UNKNOWN = 4

local line_ending_text = {"DOS (CRLF)", "MacOS (CR)", "Unix (LF)", ""}

function calc_line_ending_type(fcstr)
    if fcstr then
        if fcstr:ContainsLuaString("\r\n") then
            return LINE_ENDINGS_DOS
        elseif fcstr:ContainsLuaString("\r") then
            return LINE_ENDINGS_MAC
        elseif fcstr:ContainsLuaString("\n") then
            return LINE_ENDINGS_UNIX
        end
    end
    return LINE_ENDINGS_UNKNOWN
end

local function activate_editor()
    global_dialog:Activate()
    edit_text:SetKeyboardFocus()
end

local function get_edit_text(control)
    local retval = finale.FCString()
    control:GetText(retval)
    if finenv.UI():IsOnWindows() then
        -- Windows always returns CRLF, no matter what line endings we put in,
        -- so we have to massage the text based on the line endings we captured going in.
        if context.line_ending_type == LINE_ENDINGS_MAC then
            retval.LuaString = retval.LuaString:gsub("\r\n", "\r")
        elseif context.line_ending_type == LINE_ENDINGS_UNIX then
            retval.LuaString = retval.LuaString:gsub("\r\n", "\n")
        end
    end
    local line_ending = calc_line_ending_type(retval)
    line_ending_show:SetText(finale.FCString(line_ending_text[line_ending]))
    return retval
end

local function set_edit_text(control, fcstr, options)
    options = options or {}
    assert(type(options) == "table", "argument 3 (options) should be a table: got " .. type(options))
    context.line_ending_type = calc_line_ending_type(fcstr)
    control:SetText(fcstr)
    if not options.nocache then
        context.original_script_text = get_edit_text(control).LuaString
    end
end

local function update_script_menu(items, new_index)
    assert(items.Count > 0, "items collection contains no items")
    local curr_script_index = new_index or script_menu:GetSelectedItem()
    script_menu:Clear()
    for item in each(items) do
        --local item_string = string.gsub(item.MenuItemText, "%.{3}$", "") -- remove trailing dots, if any
        script_menu:AddString(finale.FCString(item.MenuItemText))
    end
    if curr_script_index < script_menu:GetCount() then
        script_menu:SetSelectedItem(curr_script_index)
    end
end

local function menu_index_from_current_script()
    local script_item_index = context.selected_script_item
    assert(script_item_index > 0, "invalid script_item_index")
    assert(context.script_items_list[script_item_index], "no context for script item index")
    return script_item_index - 1 + context.first_script_in_menu
end

local function kill_executing_items(item_index)
    if item_index > 0 then
        for item in each(context.script_items_list[item_index].items) do
            if item:IsExecuting() then
                item:StopExecuting()
            end
            item.ControllingWindow = nil -- piece o' the rock
        end
    end
end

local function select_script(fullpath, scripts_items_index)
    local original_fullpath = fullpath
    local fc_fullpath = finale.FCString(fullpath)
    local fc_path = finale.FCString()
    local fc_name = finale.FCString()
    local file_exists = true
    if fc_fullpath:SplitToPathAndFile(fc_path, fc_name) then
        context.working_directory = fc_path.LuaString
        context.working_directory_valid = true
    else
        fc_path.LuaString = context.working_directory
        fc_path:AssureEndingPathDelimiter()
        fc_path:AppendString(fc_fullpath)
        fullpath = fc_path.LuaString
        file_exists = false
    end
    local script_text = ""
    if file_exists then
        local file <close> = io.open(encode_file_path(fullpath), "rb")
        if file then
            script_text = file:read("a")
        else
            global_dialog:CreateChildUI():AlertInfo(
                "File does not exist, or there was as error in the encoding of the file path: " .. encode_file_path(fullpath), "File Error")
            file_exists = false
        end
    end
    kill_executing_items(context.selected_script_item)
    local script_items = finenv.CreateLuaScriptItemsFromFilePath(fullpath, script_text)
    assert(script_items.Count > 0, "No script items returned for " .. fullpath .. ".")
    if not context.script_items_list[scripts_items_index] then
        context.script_items_list[scripts_items_index] = {}
    end
    context.script_items_list[scripts_items_index].items = script_items
    context.script_items_list[scripts_items_index].exists = file_exists
    context.selected_script_item = scripts_items_index
    set_edit_text(edit_text, finale.FCString(script_text))
    if file_exists then
        local file_info = lfs.attributes(encode_file_path(fullpath))
        if file_info then
            context.modification_time = file_info.modification
        end
    end
    edit_text:ResetUndoState()
    line_number_text:ScrollToVerticalPosition(0)
    update_script_menu(script_items, 0)
    local file_menu_index = scripts_items_index + context.first_script_in_menu - 1
    if file_menu_index < file_menu:GetCount() then
        file_menu:SetItemText(file_menu_index, finale.FCString(original_fullpath))
    else
        file_menu:AddString(finale.FCString(original_fullpath))
        assert(file_menu:GetCount() == file_menu_index + 1,
            "Adding string to file_menu and file_menu_index is beyond the end of it.")
    end
    file_menu:SetSelectedItem(file_menu_index)
    file_menu_cursel = file_menu_index
    return true
end

local check_save -- forward reference to check_save function

local function file_new()
    if not check_save() then
        file_menu:SetSelectedItem(menu_index_from_current_script())
        return
    end
    select_script("Untitled" .. context.untitled_counter .. ".lua",
        file_menu:GetCount() - context.first_script_in_menu + 1)
    context.untitled_counter = context.untitled_counter + 1
end

local function file_open()
    if not check_save() then
        file_menu:SetSelectedItem(menu_index_from_current_script())
        return
    end
    local file_open_dlg = finale.FCFileOpenDialog(global_dialog:CreateChildUI())
    file_open_dlg:AddFilter(finale.FCString("*.lua"), finale.FCString("Lua source files"))
    if context.working_directory_valid then
        file_open_dlg:SetInitFolder(finale.FCString(context.working_directory))
    end
    file_open_dlg:SetWindowTitle(finale.FCString("Open Lua Source File"))
    if file_open_dlg:Execute() then
        local fc_name = finale.FCString()
        file_open_dlg:GetFileName(fc_name)
        if not select_script(fc_name.LuaString, file_menu:GetCount() - context.first_script_in_menu + 1) then
            file_menu:SetSelectedItem(menu_index_from_current_script())
        end
    else
        file_menu:SetSelectedItem(menu_index_from_current_script())
    end
end

local file_save_as -- forward reference
local function file_save()
    local script_item_index = context.selected_script_item
    if not context.script_items_list[script_item_index].exists then
        return file_save_as()
    end
    local menu_index = menu_index_from_current_script()
    local file_path = finale.FCString()
    local result = file_menu:GetItemText(menu_index, file_path)
    assert(result, "no text found in file_menu at index " .. menu_index)
    local modified_externally = (function()
        local file_info = lfs.attributes(encode_file_path(file_path.LuaString))
        return file_info and file_info.modification ~= context.modification_time
    end)()
    local retval = false
    if not modified_externally or global_dialog:CreateChildUI():AlertYesNo("Saving will overwrite changes made with another editor.", "Continue?") == finale.YESRETURN then
        local retval = true
        local file <close> = io.open(encode_file_path(file_path.LuaString), "wb")
        if file then
            local contents = get_edit_text(edit_text)
            file:write(contents.LuaString)
            local items = finenv.CreateLuaScriptItemsFromFilePath(file_path.LuaString, contents.LuaString)
            context.original_script_text = contents.LuaString
            local file_info = lfs.attributes(encode_file_path(file_path.LuaString))
            if file_info then
                context.modification_time = file_info.modification
            end
            assert(items.Count > 0, "no items returned for " .. file_path.LuaString)
            kill_executing_items(script_item_index)
            context.script_items_list[script_item_index].items = items
            retval = true
            update_script_menu(items)
        else
            global_dialog:CreateChildUI():AlertError("Unable to write file " .. file_path.LuaString, "Save Error")
            retval = false
        end
    end
    file_menu:SetSelectedItem(menu_index)
    return retval
end

function check_save(is_closing) -- "local" omitted because check_save is defined as local above
    if context.selected_script_item <= 0 then
        return true -- nothing has been loaded yet if here
    end
    local fcstr = get_edit_text(edit_text)
    if fcstr.LuaString ~= context.original_script_text then
        local ui = global_dialog:CreateChildUI()
        local function_name = is_closing and "AlertYesNo" or "AlertYesNoCancel"
        local result = ui[function_name](ui, "Would you like to save your changes to this script?", "Save Changes?")
        if result == finale.YESRETURN then
            return file_save()
        end
        if result == finale.CANCELRETURN then
            return false
        end
    end
    return true -- ToDo: check if we need to save changes
end

function file_save_as()
    local script_item_index = context.selected_script_item
    local menu_index = menu_index_from_current_script()
    local fc_path = finale.FCString()
    local got_menu_text = file_menu:GetItemText(menu_index, fc_path)
    assert(got_menu_text, "unable to get popup item text for item" .. menu_index)
    local file_save_dlg = finale.FCFileSaveAsDialog(global_dialog:CreateChildUI())
    local fc_folder = finale.FCString()
    local fc_name = finale.FCString()
    if fc_path:SplitToPathAndFile(fc_folder, fc_name) then
        file_save_dlg:SetInitFolder(fc_folder)
        file_save_dlg:SetFileName(fc_name)
    else
        if context.working_directory_valid then
            file_save_dlg:SetInitFolder(finale.FCString(context.working_directory))
        end
        file_save_dlg:SetFileName(fc_path)
    end
    file_save_dlg:AddFilter(finale.FCString("*.lua"), finale.FCString("Lua source files"))
    file_save_dlg:SetWindowTitle(finale.FCString("Save Lua Source File As"))
    local result = file_save_dlg:Execute()
    if result then
        context.script_items_list[script_item_index].exists = true
        local fc_new_path = finale.FCString()
        file_save_dlg:AssureFileExtension(".lua")
        file_save_dlg:GetFileName(fc_new_path, nil)
        fc_new_path:SplitToPathAndFile(fc_folder, nil)
        context.working_directory = fc_folder.LuaString
        context.working_directory_valid = true
        file_menu:SetItemText(menu_index, fc_new_path)
        file_save()
    end
    file_menu:SetSelectedItem(menu_index)
    return result
end

local function do_file_close(all_files)
    if not check_save() then
        file_menu:SetSelectedItem(menu_index_from_current_script())
        return
    end
    local first_menu_index = all_files and context.first_script_in_menu or menu_index_from_current_script()
    local last_menu_index = all_files and file_menu:GetCount() - 1 or first_menu_index
    assert(last_menu_index >= first_menu_index, "attempt to close more files than there are")
    for menu_index = last_menu_index, first_menu_index, -1 do
        assert(menu_index >= context.first_script_in_menu, "attempt to delete base file menu item")
        file_menu:DeleteItem(menu_index)
        local script_items_index = first_menu_index - context.first_script_in_menu + 1
        kill_executing_items(script_items_index)
        table.remove(context.script_items_list, script_items_index)
    end
    if all_files then
        context.selected_script_item = 1
    end
    if first_menu_index >= file_menu:GetCount() then
        first_menu_index = first_menu_index - 1
        assert(first_menu_index < file_menu:GetCount(), "menu index is out of range after deletion: " .. first_menu_index)
        context.selected_script_item = context.selected_script_item - 1
        if first_menu_index < context.first_script_in_menu then
            file_new()
            return -- file_new() sets the correct selection
        else
            assert(context.selected_script_item > 0, "context.selected_script_item has gone to zero")
            local filepath = finale.FCString()
            file_menu:GetItemText(first_menu_index, filepath)
            select_script(filepath.LuaString, context.selected_script_item)
        end
    else
        local filepath = finale.FCString()
        file_menu:GetItemText(first_menu_index, filepath)
        select_script(filepath.LuaString, context.selected_script_item)
    end
    file_menu:SetSelectedItem(first_menu_index)
end    

file_menu_base_handler =
{
    file_new,
    file_open,
    file_save,
    file_save_as,
    function()
        do_file_close(false)
    end,
    function() -- nop function for divider
        file_menu:SetSelectedItem(menu_index_from_current_script())
    end,
    function()
        do_file_close(true)
    end,
    function() -- nop function for divider
        file_menu:SetSelectedItem(menu_index_from_current_script())
    end
}

local function calc_tab_width(font, numchars)
    if finale.FCDocument().ID > 0 then
        --update value if we have a document
        local font_info = finale.FCFontInfo(config.font_name, config.font_size)
        config.font_advance_points = font_info:CalcAverageRomanCharacterWidthPoints()
    end
    return numchars * config.font_advance_points
end

local function setup_editor_control(control, width, height, editable, tabstop_width)
    control:SetWidth(width)
    control:SetHeight(height)
    control:SetReadOnly(not editable)
    control:SetUseRichText(false)
    control:SetWordWrap(false)
    control:SetAutomaticEditing(false)
    if finenv.UI():IsOnMac() then
        control:SetLineSpacing(config.editor_line_spacing)
    end
    local font = finale.FCFontInfo(config.font_name, config.font_size)
    control:SetFont(font)
    if tabstop_width then
        control:SetTabstopWidth(calc_tab_width(font, tabstop_width))
    end
    return control
end

function output_to_console(...)
    local time_stamp = ""
    if config.show_timestamps then
        local proc_time = hires_timer and (finale.FCUI.GetHiResTimer() - hires_timer) or 0
        time_stamp = string.format("%.3f", proc_time) .. ": "
    end
    local args = { ... } -- Pack all arguments into a table
    local formatted_args = {}
    for i, arg in ipairs(args) do
        formatted_args[i] = tostring(arg) -- Convert each argument to a string
    end
    local range = finale.FCRange()
    output_text:GetTotalTextRange(range)
    local new_line = range.Length > 0 and "\n"..time_stamp or time_stamp
    local formatted_string = new_line .. table.concat(formatted_args, "\t") -- Concatenate arguments with tabs
    output_text:AppendText(finale.FCString(formatted_string))
    output_text:ScrollToBottom()
    output_text:RedrawImmediate()
end

local function write_line_numbers(num_lines)
    local function format_number(num, width)
        local str_num = tostring(num)
        local leading_spaces = width - #str_num
        if leading_spaces < 0 then
            leading_spaces = 0
        end
        local trailing_space = finenv.UI():IsOnWindows() and " " or ""
        return string.rep(" ", leading_spaces) .. str_num .. trailing_space
    end
    local numbers_text = ""
    line_number = 1
    context.line_numbers = {}
    for i = 1, num_lines do
        local do_number = true
        if config.word_wrap and i > 1 then
            local line_range = finale.FCRange()
            edit_text:GetLineRangeForLine(i, line_range)
            local prev_line_char = edit_text:CreateCharacterAtIndex(line_range.Start - 1)
            if prev_line_char and prev_line_char.LuaString ~= "\n" and prev_line_char.LuaString ~= "\r" then
                do_number = false
            end
        end
        local line_ending = i < num_lines and "\n" or ""
        if do_number then
            context.line_numbers[line_number] = i
            numbers_text = numbers_text .. format_number(line_number, 6) .. line_ending
            line_number = line_number + 1
        else
            numbers_text = numbers_text .. line_ending
        end
    end
    line_number_text:SetText(finale.FCString(numbers_text))
    line_number_text:ResetColors() -- mainly needed on macOS
end

function on_text_change(control)
    if in_text_change_event then
        return
    end
    in_text_change_event = true
    assert(control:GetControlID() == edit_text:GetControlID(), "on_text_change called for wrong control")
    local num_lines = control:GetNumberOfLines() -- this matches code lines because there is no word-wrap
    if num_lines < 1 then num_lines = 1 end
    if config.word_wrap or num_lines ~= line_number_text:GetNumberOfLines() then
        -- checking if the number of lines changed avoids churn.
        write_line_numbers(num_lines)
    end
    -- Syntax highlighting could happen here, but it is non-trivial due issues
    -- around performance and disruption of the Undo stack. (Not to mention the need
    -- to intelligently parse Lua code.)
    in_text_change_event = false
end

function on_modal_window_will_open(_item)
    assert(modal_depth >= 0, "modal_depth is negative")
    if modal_depth == 0 then
        file_menu:SetEnable(false)
        kill_script_cmd:SetEnable(false)
        run_script_cmd:SetEnable(false)
        close_btn:SetEnable(false)
        global_dialog:SetPreventClosing(true)
    end
    modal_depth = modal_depth + 1
end

function on_modal_window_did_close(item)
    assert(modal_depth > 0, "modal_depth is 0 or less")
    modal_depth = modal_depth - 1
    if modal_depth == 0 then
        file_menu:SetEnable(true)
        kill_script_cmd:SetEnable(item:IsExecuting() and not in_execute_script_item)
        run_script_cmd:SetEnable(true)
        close_btn:SetEnable(true)
        global_dialog:SetPreventClosing(false)
    end
end

function on_execution_will_start(item)
    kill_script_cmd:SetEnable(not in_execute_script_item)
    output_to_console("Running [" .. item.MenuItemText .. "] ======>")
    hires_timer = finale.FCUI.GetHiResTimer()
end

function on_execution_did_stop(item, success, msg, msgtype, line_number, source)
    local proc_time = finale.FCUI.GetHiResTimer() - hires_timer
    local processing_time_str = " (Processing time: " .. string.format("%.3f", proc_time) .. " s)"
    if msg and msgtype ~= finenv.MessageResultType.LUA_ERROR then -- Any Lua error was already printed
        output_to_console(msg)
    end
    if success then
        output_to_console("<======= [" .. item.MenuItemText .. "] succeeded." .. processing_time_str)
    else
        if line_number > 0 then
            actual_line_number = context.line_numbers[line_number]
            line_range = finale.FCRange()
            line_number_text:GetLineRangeForLine(actual_line_number, line_range)
            total_range = finale.FCRange()
            line_number_text:GetTotalTextRange(total_range)
            if line_range.End < total_range.End then
                line_range.Length = line_range.Length + 1
            end
            line_number_text:SetBackgroundColorInRange(255, 102, 102, line_range) -- Red background suitable for both white and black foreground
            line_number_text:ScrollLineIntoView(actual_line_number)
        end
        local final_result = (msgtype == finenv.MessageResultType.EXTERNAL_TERMINATION) and "terminated" or "FAILED"
        output_to_console("<======= [" .. item.MenuItemText .. "] " .. final_result .. "." .. processing_time_str)
    end
    item.ControllingWindow = nil
    hires_timer = nil
    if modal_depth > 0 then
        modal_depth = 1
        on_modal_window_did_close(item)
    end
    kill_script_cmd:SetEnable(false)
end

local function on_clear_output(control)
    output_text:SetText(finale.FCString(""))
    activate_editor()
end

local function on_copy_output(control)
    local text_for_output = finale.FCString()
    output_text:GetText(text_for_output)
    local line_ending = #text_for_output.LuaString > 0 and "\n" or ""
    finenv.UI():TextToClipboard(text_for_output.LuaString .. line_ending)
    activate_editor()
end

local function on_run_script(control)
    activate_editor() -- do this first, in case the script opens a dialog
    local script_text = get_edit_text(edit_text)
    local script_items = context.script_items_list[context.selected_script_item].items
    local file_exists = context.script_items_list[context.selected_script_item].exists
    local script_item = script_items:GetItemAt(script_menu:GetSelectedItem())
    if file_exists and script_text.LuaString == context.original_script_text then
        script_item.OptionalScriptText = nil -- this allows the filename to be used for error reporting
    else
        script_item.OptionalScriptText = script_text.LuaString
    end
    script_item.AutomaticallyReportErrors = false
    script_item.Debug = run_as_debug_chk:GetCheck() ~= 0
    script_item.Trusted = run_as_trusted_chk:GetCheck() ~= 0
    script_item.ControllingWindow = global_dialog
    script_item:RegisterPrintFunction(output_to_console)
    script_item:RegisterOnExecutionWillStart(on_execution_will_start)
    script_item:RegisterOnExecutionDidStop(on_execution_did_stop)
    script_item:RegisterOnModalWindowWillOpen(on_modal_window_will_open)
    script_item:RegisterOnModalWindowDidClose(on_modal_window_did_close)
    if clear_output_chk:GetCheck() ~= 0 then
        output_text:SetText(finale.FCString(""))
    end
    line_number_text:ResetColors()
    in_execute_script_item = true
    finenv.ExecuteLuaScriptItem(script_item)
    in_execute_script_item = false
    kill_script_cmd:SetEnable(script_item:IsExecuting())
end

local function on_terminate_script(control)
    local script_items = context.script_items_list[context.selected_script_item].items
    local script_item = script_items:GetItemAt(script_menu:GetSelectedItem())
    if script_item:IsExecuting() then
        script_item:StopExecuting()
    end
    activate_editor()
end

local function on_file_popup(control)
    if in_popup_handler then
        return
    end
    in_popup_handler = true
    local selected_item = control:GetSelectedItem()
    if file_menu_cursel ~= selected_item then -- avoid Windows churn
        file_menu_cursel = selected_item
        file_menu:SetEnable(false)
        if selected_item < context.first_script_in_menu then
            file_menu_base_handler[selected_item + 1]()
        else
            local selected_script = selected_item - context.first_script_in_menu + 1
            if check_save() then -- check_save() may change context.first_script_in_menu
                if selected_script ~= context.selected_script_item then
                    local filepath = finale.FCString()
                    file_menu:GetItemText(selected_item, filepath)
                    if not select_script(filepath.LuaString, selected_script) then
                        file_menu:SetSelectedItem(menu_index_from_current_script())
                    end
                end
            end
        end
        file_menu:SetEnable(true)
        file_menu_cursel = control:GetSelectedItem()
    end
    in_popup_handler = false
    -- do not put edit_text in focus here, because it messes up Windows
end

local function on_config_dialog()
    if finale.FCDocument().ID <= 0 then
        global_dialog:CreateChildUI():AlertInfo("The Preferences dialog is only available when a document is open.",
            "Document Required")
        activate_editor()
        return
    end
    local curr_y = 0
    local y_separator = 27 -- includes control height
    local x_rightcol = 160
    local win_edit_offset = 5
    local mac_edit_offset = 3
    local dlg = finale.FCCustomLuaWindow()
    dlg:SetTitle(finale.FCString("Console Preferences"))
    --
    local total_width_label = dlg:CreateStatic(0, curr_y)
    total_width_label:SetText(finale.FCString("Total Width"))
    total_width_label:SetWidth(x_rightcol-20)
    local total_width = dlg:CreateEdit(x_rightcol, curr_y - win_mac(win_edit_offset, mac_edit_offset))
    total_width:SetInteger(config.total_width)
    curr_y = curr_y + y_separator
    --
    local editor_height_label = dlg:CreateStatic(0, curr_y)
    editor_height_label:SetText(finale.FCString("Editor Height"))
    editor_height_label:SetWidth(x_rightcol-20)
    local editor_height = dlg:CreateEdit(x_rightcol, curr_y - win_mac(win_edit_offset, mac_edit_offset))
    editor_height:SetInteger(config.editor_height)
    curr_y = curr_y + y_separator
    --
    -- Windows can't do line spacing when UseRichText is false, so don't provide the option.
    -- The good news is that Windows keeps the line spacing exactly the same even for international
    -- characters, so the main need for it in the console is already addressed.
    local editor_linespacing
    if finenv.UI():IsOnMac() then
        local editor_linespacing_label = dlg:CreateStatic(0, curr_y)
        editor_linespacing_label:SetText(finale.FCString("Editor Line Spacing"))
        editor_linespacing_label:SetWidth(x_rightcol-20)
        editor_linespacing = dlg:CreateEdit(x_rightcol, curr_y - win_mac(win_edit_offset, mac_edit_offset))
        editor_linespacing:SetFloat(config.editor_line_spacing)
        curr_y = curr_y + y_separator
    end
    --
    local output_height_label = dlg:CreateStatic(0, curr_y)
    output_height_label:SetText(finale.FCString("Output Console Height"))
    output_height_label:SetWidth(x_rightcol-20)
    local output_height = dlg:CreateEdit(x_rightcol, curr_y - win_mac(win_edit_offset, mac_edit_offset))
    output_height:SetInteger(config.output_console_height)
    curr_y = curr_y + y_separator
    --
    local tab_stop_width_label = dlg:CreateStatic(0, curr_y)
    tab_stop_width_label:SetText(finale.FCString("Tabstop Width"))
    tab_stop_width_label:SetWidth(x_rightcol-20)
    local tab_stop_width = dlg:CreateEdit(x_rightcol, curr_y - win_mac(win_edit_offset, mac_edit_offset))
    tab_stop_width:SetInteger(config.tabstop_width)
    curr_y = curr_y + y_separator
    --
    local tabs_to_spaces = dlg:CreateCheckbox(0, curr_y)
    tabs_to_spaces:SetText(finale.FCString("Use Spaces for Tabs"))
    tabs_to_spaces:SetWidth(x_rightcol - 20)
    tabs_to_spaces:SetCheck(config.tabs_to_spaces and 1 or 0)
    curr_y = curr_y + y_separator
    --
    local word_wrap = dlg:CreateCheckbox(0, curr_y)
    word_wrap:SetText(finale.FCString("Wrap Text in Editor"))
    word_wrap:SetWidth(x_rightcol - 20)
    word_wrap:SetCheck(config.word_wrap and 1 or 0)
    curr_y = curr_y + y_separator
    --
    local show_time = dlg:CreateCheckbox(0, curr_y)
    show_time:SetText(finale.FCString("Show Timestamps in Output"))
    show_time:SetWidth(x_rightcol + 20)
    show_time:SetCheck(config.show_timestamps and 1 or 0)
    curr_y = curr_y + y_separator
    --
    local output_tab_width_label = dlg:CreateStatic(0, curr_y)
    output_tab_width_label:SetText(finale.FCString("Output Tabstop Width"))
    output_tab_width_label:SetWidth(x_rightcol-20)
    local output_tab_width = dlg:CreateEdit(x_rightcol, curr_y - win_mac(win_edit_offset, mac_edit_offset))
    output_tab_width:SetInteger(config.output_tabstop_width)
    curr_y = curr_y + y_separator
    --
    local output_wrap = dlg:CreateCheckbox(0, curr_y)
    output_wrap:SetText(finale.FCString("Wrap Text in Output"))
    output_wrap:SetWidth(x_rightcol - 20)
    output_wrap:SetCheck(config.output_wrap and 1 or 0)
    curr_y = curr_y + y_separator
    --
    local font_label = dlg:CreateStatic(0, curr_y)
    font_label:SetWidth(x_rightcol-20)
    local function set_font_text(font_info)
        local font_label_text = finale.FCString("Font")
        font_label_text:AppendString(font_info:CreateDescription())
        font_label:SetText(font_label_text)
    end
    local font = finale.FCFontInfo(config.font_name, config.font_size)
    set_font_text(font)
    local font_change = dlg:CreateButton(x_rightcol, curr_y - win_mac(win_edit_offset, mac_edit_offset))
    font_change:SetText(finale.FCString("Change..."))
    font_change:SetWidth(70)
    dlg:RegisterHandleControlEvent(font_change, function(control)
        local font_selector = finale.FCFontDialog(dlg:CreateChildUI(), font)
        if font_selector:Execute() then
            font:SetEnigmaStyles(0)
            set_font_text(font)
        end
    end)
    --
    dlg:CreateOkButton()
    dlg:CreateCancelButton()
    if dlg:ExecuteModal(global_dialog) == finale.EXECMODAL_OK then
        config.total_width = math.max(580, total_width:GetInteger())
        config.editor_height = math.max(120, editor_height:GetInteger())
        config.editor_line_spacing = editor_linespacing and editor_linespacing:GetFloat(0, math.huge) or 0
        config.output_console_height = math.max(60, output_height:GetInteger())
        config.tabstop_width = math.max(0, tab_stop_width:GetInteger())
        config.tabs_to_spaces = tabs_to_spaces:GetCheck() ~= 0
        config.word_wrap = word_wrap:GetCheck() ~= 0
        config.show_timestamps = show_time:GetCheck() ~= 0
        config.output_wrap = output_wrap:GetCheck() ~= 0
        config.output_tabstop_width = math.max(1, output_tab_width:GetInteger())
        local fcstr = finale.FCString()
        font:GetNameString(fcstr)
        config.font_name = fcstr.LuaString
        config.font_size = font:GetSize()
        config.font_advance_points = font:CalcAverageRomanCharacterWidthPoints()
        global_dialog:CreateChildUI():AlertInfo("Changes will take effect the next time you open the console.", "Changes Accepted")
    end
    activate_editor()
end

local function on_scroll(control)
    if in_scroll_handler then
        return
    end
    in_scroll_handler = true
    local target_pos = control:GetVerticalScrollPosition()
    if control:GetControlID() == edit_text:GetControlID() then
        line_number_text:ScrollToVerticalPosition(target_pos)
    elseif control:GetControlID() == line_number_text:GetControlID() then
        edit_text:ScrollToVerticalPosition(target_pos)
    end
    in_scroll_handler = false
end

local function on_init_window()
    for _, str in pairsbykeys(context.file_menu_base) do
        file_menu:AddString(finale.FCString(str))
    end
    for _, itemcontext in pairsbykeys(context.script_items_list) do
        local items = itemcontext.items
        local str = items:GetItemAt(0).FilePath
        if not itemcontext.exists then
            local fc_str = finale.FCString(str)
            local fc_name = finale.FCString()
            fc_str:SplitToPathAndFile(nil, fc_name)
            str = fc_name.LuaString
        end
        file_menu:AddString(finale.FCString(str))
    end
    if file_menu:GetCount() <= context.first_script_in_menu then
        file_new()
    else
        local menu_idx = menu_index_from_current_script()
        local fc_str = finale.FCString()
        file_menu:GetItemText(menu_idx, fc_str)
        select_script(fc_str.LuaString, context.selected_script_item)
    end
    kill_script_cmd:SetEnable(false)
    clear_output_chk:SetCheck(config.clear_output_before_run and 1 or 0)
    run_as_debug_chk:SetCheck(config.run_as_debug and 1 or 0)
    run_as_trusted_chk:SetCheck(config.run_as_trusted and run_as_trusted_chk:GetEnable() and 1 or 0)
    if context.script_text then
        set_edit_text(edit_text, finale.FCString(context.script_text), {nocache = true})
    end
    write_line_numbers(math.max(edit_text:GetNumberOfLines(), 1))
    edit_text:ResetUndoState()
    if context.output_text then
        output_text:SetText(finale.FCString(""))
        output_text:AppendText(finale.FCString(context.output_text)) -- AppendText scrolls to the end
    end
    activate_editor()
    global_dialog:SetTimer(global_timer_id, 100) --100ms should be plenty for checking if the file has been written externally
end

local function on_close_window()
    global_dialog:StopTimer(global_timer_id)
    if global_dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_ALT) or global_dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_SHIFT) then
        finenv.RetainLuaState = false
    else
        finenv.RetainLuaState = true
    end
    check_save(true) -- true: is closing
    config.clear_output_before_run = clear_output_chk:GetCheck() ~= 0
    config.run_as_debug = run_as_debug_chk:GetCheck() ~= 0
    config.run_as_trusted = run_as_trusted_chk:GetCheck() ~= 0
    local recent_files_index = 0
    config.recent_files = {}
    config.curr_script_item = context.selected_script_item
    for idx, items_entry in ipairs(context.script_items_list) do
        if items_entry.exists and items_entry.items.Count > 0 then
            recent_files_index = recent_files_index + 1
            local fp = items_entry.items:GetItemAt(0).FilePath
            config.recent_files[recent_files_index] = items_entry.items:GetItemAt(0).FilePath
        elseif idx <= context.selected_script_item then
            config.curr_script_item = config.curr_script_item - 1
        end
    end
    global_dialog:StorePosition()
    config.window_pos_x = global_dialog.StoredX
    config.window_pos_y = global_dialog.StoredY
    config.window_pos_valid = true
    config_write()
    on_terminate_script()
    if finenv.RetainLuaState then
        context.script_text = get_edit_text(edit_text).LuaString
        if context.script_text == context.original_script_text then
            -- if we are in a saved state, do not keep the current contents.
            -- an external editor could modify the file and if we kept our current
            -- version, we would erroneously believe we had edited it.
            context.script_text = nil
        end
        context.output_text = get_edit_text(output_text).LuaString
    end
    -- clear edit controls for speedier exit, esp. on Windows
    -- See PDK docs for FCCtrlTextEditor::CreateEnigmaString
    edit_text:SetText(finale.FCString())
    line_number_text:SetText(finale.FCString())
    output_text:SetText(finale.FCString())
end

local function find_again(from_current)
    assert(context.search_pattern == nil or type(context.search_pattern) == "string", "search pattern is not a string")
    if not context.search_pattern or #context.search_pattern == 0 then
        return
    end
    local options = 0
    if config.search_regex then
        options = options | finale.STRFINDOPT_REGEX
    end
    if config.search_ignore_case then
        options = options | finale.STRFINDOPT_IGNORECASE
    end
    if config.search_whole_words then
        options = options | finale.STRFINDOPT_WHOLEWORDS
    end
    local selected_range = finale.FCRange()
    edit_text:GetSelection(selected_range)
    local curr_pos = selected_range.Start
    local use_curr_sel = from_current and config.search_currsel and selected_range.Length > 0
    if not use_curr_sel then
        edit_text:GetTotalTextRange(selected_range)
    end
    local ranges = edit_text:CreateRangesForString(finale.FCString(context.search_pattern), options, selected_range)
    local found_range = nil
    if ranges then
        if from_current then
            curr_pos = curr_pos - 1
        end
        for range in each(ranges) do
            if range.Start > curr_pos then
                found_range = range
                break
            end
        end
        if not found_range then
            found_range = ranges:GetItemAt(0)
        end
    end
    if found_range then
        edit_text:ScrollLineIntoView(edit_text:GetLineForPosition(found_range.Start)) -- Windows needs to scroll before setting selection
        edit_text:SetSelection(found_range)
    else
        local message = "Search pattern not found"
        if use_curr_sel then
            message = message .. " in current selection"
        end
        global_dialog:CreateChildUI():AlertInfo(message .. ".", "Not Found")
    end
    activate_editor()
end

local function find_text()
    local curr_y = 0
    local curr_x = 0
    local y_separator = 27 -- includes control height
    local x_separator = 5
    local win_edit_offset = 5
    local mac_edit_offset = 3
    local check_box_width = 100
    local dlg = finale.FCCustomLuaWindow()
    dlg:SetTitle(finale.FCString("Find Text"))
    --
    local find_text_label = dlg:CreateStatic(curr_x, curr_y)
    find_text_label:SetText(finale.FCString("Text:"))
    find_text_label:SetWidth(40)
    curr_x = curr_x + 45
    local find_text = dlg:CreateEdit(curr_x, curr_y - win_mac(win_edit_offset, mac_edit_offset))
    find_text:SetText(finale.FCString(context.search_text))
    find_text:SetWidth(check_box_width * 3)
    curr_y = curr_y + y_separator
    --
    curr_x = 0
    local case_sensitive = dlg:CreateCheckbox(curr_x, curr_y)
    case_sensitive:SetText(finale.FCString("Case Sensitive"))
    case_sensitive:SetWidth(check_box_width)
    curr_x = curr_x + check_box_width + x_separator
    local whole_words = dlg:CreateCheckbox(curr_x, curr_y)
    whole_words:SetText(finale.FCString("Whole Words"))
    whole_words:SetWidth(check_box_width)
    curr_x = curr_x + check_box_width + x_separator
    local regular_expressions = dlg:CreateCheckbox(curr_x, curr_y)
    regular_expressions:SetText(finale.FCString("Regular Expressions"))
    regular_expressions:SetWidth(check_box_width + 30)
    dlg:RegisterHandleControlEvent(regular_expressions, function(control)
        whole_words:SetEnable(control:GetCheck() == 0)
    end)
    curr_y = curr_y + y_separator
    --
    curr_x = 0
    local current_selection_only = dlg:CreateCheckbox(curr_x, curr_y)
    current_selection_only:SetText(finale.FCString("Current Selection Only"))
    current_selection_only:SetWidth(2 * check_box_width)
    curr_y = curr_y + y_separator
    --
    dlg:CreateOkButton()
    dlg:CreateCancelButton()
    dlg:RegisterInitWindow(function()
        find_text:SetText(finale.FCString(context.search_pattern))
        case_sensitive:SetCheck(not config.search_ignore_case and 1 or 0)
        whole_words:SetCheck(config.search_whole_words and 1 or 0)
        whole_words:SetEnable(not config.search_regex)
        regular_expressions:SetCheck(config.search_regex and 1 or 0)
        current_selection_only:SetCheck(config.search_currsel and 1 or 0)
        local sel_range = finale.FCRange()
        edit_text:GetSelection(sel_range)
        current_selection_only:SetEnable(sel_range.Length > 0)
    end)
    if dlg:ExecuteModal(global_dialog) == finale.EXECMODAL_OK then
        local fctext = finale.FCString()
        find_text:GetText(fctext)
        context.search_pattern = fctext.LuaString
        config.search_ignore_case = case_sensitive:GetCheck() == 0
        config.search_whole_words = whole_words:GetCheck() ~= 0
        config.search_regex = regular_expressions:GetCheck() ~= 0
        config.search_currsel = current_selection_only:GetCheck() ~= 0
        find_again(true)
    end
    activate_editor()
end

local function on_timer(timer_id)
    if timer_id ~= global_timer_id then return end
    if in_timer then
        return
    end
    in_timer = true
    if find_requested then
        find_text()
        find_requested = false
    end
    local list_item = context.script_items_list[context.selected_script_item]
    if list_item.exists then
        assert(list_item.items.Count > 0, "list items exist but there are no script items")
        assert(context.modification_time, "modification time was not set")
        local filepath = list_item.items:GetItemAt(0).FilePath
        local file_info = lfs.attributes(encode_file_path(filepath))
        if file_info and file_info.modification ~= context.modification_time then
            local script_text = get_edit_text(edit_text)
            if context.original_script_text == script_text.LuaString then -- no modifications here
                local file <close> = io.open(encode_file_path(filepath), "rb")
                if file then
                    local modified_text = file:read("a")
                    local curr_scroll_pos = line_number_text:GetVerticalScrollPosition()
                    set_edit_text(edit_text, finale.FCString(modified_text))
                    context.modification_time = file_info.modification
                    line_number_text:ScrollToVerticalPosition(curr_scroll_pos)
                    list_item.items = finenv.CreateLuaScriptItemsFromFilePath(filepath, modified_text)
                    update_script_menu(list_item.items)
                end
            end
        end
    end
    in_timer = false
end

local function on_find_text()
    if finenv:UI():IsOnMac() then
        return find_text()
    end
    -- It appears FX_Dialog cannot open a new dialog inside a WM_KEYDOWN handler, so work around it
    find_requested = true
end

local keyboard_command_funcs = { S = file_save, O = file_open, N = file_new, F = on_find_text, G = find_again, W = do_file_close }
local function on_keyboard_command(control, character)
    local char_string = utf8.char(character)
    if not keyboard_command_funcs[char_string] then
        return false
    end
    if finenv.UI():IsOnMac() and char_string == "N" then
        if not global_dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_SHIFT) then
            return false
        end
    end
    if modal_depth <= 0 then
        keyboard_command_funcs[char_string]()
    end
    return true
end

local create_dialog = function()
    local dialog = finale.FCCustomLuaWindow()
    dialog:SetTitle(finale.FCString("RGP Lua - Console v" .. finaleplugin.Version))
    -- positioning parameters
    local x_separator = 10
    local y_separator = 10
    local button_width = 100
    local small_button_width = 70
    local button_height = 20
    local check_box_width = win_mac(105, 120)
    local edit_text_height = config.editor_height
    local output_height = config.output_console_height
    local line_number_width = math.ceil(config.font_advance_points * win_mac(7, 6) + 35)
    local total_width = config.total_width
    local curr_y = 0
    local curr_x = 0
    -- script selection
    file_menu = dialog:CreatePopup(0, curr_y)
    local one_third_width = total_width / 3
    file_menu:SetWidth(2*one_third_width - x_separator/2)
    script_menu = dialog:CreatePopup(total_width - one_third_width + 5, curr_y)
    script_menu:SetWidth(one_third_width - x_separator/2)
    curr_y = curr_y + button_height + y_separator
    -- editor
    line_number_text = setup_editor_control(dialog:CreateTextEditor(0, curr_y), line_number_width, edit_text_height, false)
    if finenv.UI():IsOnWindows() then
        line_number_text:SetUseRichText(true) -- this is needed on Windows for color flagging.
    end
    line_number_text:SetWordWrap(config.word_wrap) -- this matches the presence/absence of a horizonal scrollbar on the editor
    edit_text = setup_editor_control(dialog:CreateTextEditor(line_number_width + x_separator, curr_y),
        total_width - line_number_width - x_separator, edit_text_height, true, config.tabstop_width)
    edit_text:SetConvertTabsToSpaces(config.tabs_to_spaces and config.tabstop_width or 0)
    edit_text:SetAutomaticallyIndent(true)
    edit_text:SetWordWrap(config.word_wrap)
    curr_y = curr_y + y_separator + edit_text_height
    -- command buttons, misc.
    curr_x = 0
    run_as_trusted_chk = dialog:CreateCheckbox(curr_x, curr_y)
    run_as_trusted_chk:SetText(finale.FCString("Run As Trusted"))
    run_as_trusted_chk:SetWidth(check_box_width)
    run_as_trusted_chk:SetEnable(finenv.TrustedMode ~= finenv.TrustedModeType.UNTRUSTED)
    curr_x = curr_x + check_box_width + x_separator
    run_as_debug_chk = dialog:CreateCheckbox(curr_x, curr_y)
    run_as_debug_chk:SetText(finale.FCString("Run As Debug"))
    run_as_debug_chk:SetWidth(check_box_width)
    curr_x = curr_x + check_box_width + x_separator
    line_ending_show = dialog:CreateStatic(curr_x, curr_y)
    line_ending_show:SetWidth(button_width)
    curr_x = curr_x + button_width + x_separator
    kill_script_cmd = dialog:CreateButton(curr_x, curr_y - win_mac(5, 1))
    kill_script_cmd:SetText(finale.FCString("Stop Script"))
    kill_script_cmd:SetWidth(button_width)
    curr_x = curr_x + button_width + x_separator
    run_script_cmd = dialog:CreateButton(total_width - button_width, curr_y - win_mac(5, 1))
    run_script_cmd:SetText(finale.FCString("Run Script"))
    run_script_cmd:SetWidth(button_width)
    curr_y = curr_y + button_height + y_separator
    -- output console
    curr_x = 0
    local output_desc = dialog:CreateStatic(curr_x, curr_y)
    output_desc:SetWidth(100)
    output_desc:SetText(finale.FCString("Execution Output:"))
    curr_x = curr_x + 100 + x_separator
    local clear_now = dialog:CreateButton(curr_x, curr_y - win_mac(5,1))
    clear_now:SetText(finale.FCString("Clear"))
    clear_now:SetWidth(small_button_width)
    curr_x = curr_x + small_button_width + x_separator
    local copy_output = dialog:CreateButton(curr_x, curr_y - win_mac(5, 1))
    copy_output:SetText(finale.FCString("Copy"))
    copy_output:SetWidth(small_button_width)
    clear_output_chk = dialog:CreateCheckbox(total_width - check_box_width, curr_y)
    clear_output_chk:SetWidth(check_box_width)
    clear_output_chk:SetText(finale.FCString("Clear Before Run"))
    curr_y = curr_y + button_height
    output_text = setup_editor_control(dialog:CreateTextEditor(0, curr_y), total_width, output_height, false,
        config.output_tabstop_width)
    output_text:SetWordWrap(config.output_wrap)
    curr_y = curr_y + output_height + y_separator
    -- close button line
    curr_x = 0
    local config_btn = dialog:CreateButton(curr_x, curr_y)
    config_btn:SetText(finale.FCString("Preferences..."))
    config_btn:SetWidth(100)
    curr_x = curr_x + 100 + x_separator
    local search_btn = dialog:CreateButton(curr_x, curr_y)
    search_btn:SetWidth(80)
    search_btn:SetText(finale.FCString("Search..."))
    curr_x = curr_x + 80 + x_separator
    local browser_btn = dialog:CreateButton(curr_x, curr_y)
    browser_btn:SetText(finale.FCString("Class Browser..."))
    browser_btn:SetWidth(110)
    browser_btn:SetEnable(browser_script_item ~= nil)
    curr_x = curr_x + 110 + x_separator
    close_btn = dialog:CreateCloseButton(total_width - small_button_width, curr_y)
    close_btn:SetWidth(small_button_width)
    -- registrations
    dialog:RegisterHandleControlEvent(run_script_cmd, on_run_script)
    dialog:RegisterHandleControlEvent(kill_script_cmd, on_terminate_script)
    dialog:RegisterHandleControlEvent(file_menu, on_file_popup)
    dialog:RegisterHandleControlEvent(edit_text, on_text_change)
    dialog:RegisterHandleControlEvent(clear_now, on_clear_output)
    dialog:RegisterHandleControlEvent(copy_output, on_copy_output)
    dialog:RegisterHandleControlEvent(config_btn, on_config_dialog)
    dialog:RegisterHandleControlEvent(search_btn, function(control)
        if dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_SHIFT) then
            find_again()
        else
            find_text()
        end
    end)
    dialog:RegisterHandleControlEvent(browser_btn, function(control)
        activate_editor() -- activate first, since this will launch another modeless window
        if browser_script_item then
            finenv.ExecuteLuaScriptItem(browser_script_item)
        end
    end)
    dialog:RegisterScrollChanged(on_scroll)
    dialog:RegisterInitWindow(on_init_window)
    dialog:RegisterCloseWindow(on_close_window)
    dialog:RegisterHandleTimer(on_timer)
    dialog:RegisterHandleKeyboardCommand(on_keyboard_command)
    return dialog
end

local open_console = function()
    config_read()
    if not finenv.RetainLuaState then
        local script_items_index = 0
        for _, file_path in ipairs(config.recent_files) do
            local items = finenv.CreateLuaScriptItemsFromFilePath(file_path)
            if items and items.Count > 0 then
                script_items_index = script_items_index + 1
                context.script_items_list[script_items_index] = {}
                context.script_items_list[script_items_index].items = items
                context.script_items_list[script_items_index].exists = true
            end
        end
        if script_items_index > 0 then
            if config.curr_script_item >= 1 then
                context.selected_script_item = config.curr_script_item
            else
                context.selected_script_item = 1
            end
        end
    end
    global_dialog = create_dialog()
    finenv.RegisterModelessDialog(global_dialog)
    -- For some reason we need to do this here rather than in InitWindow.
    if config.window_pos_valid then
        global_dialog:StorePosition()
        global_dialog:SetRestorePositionOnlyData(config.window_pos_x, config.window_pos_y)
        global_dialog:RestorePosition()
    end
    global_dialog:ShowModeless()
end

open_console()
