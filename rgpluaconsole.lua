function plugindef()
    -- This function and the 'finaleplugin' namespace
    -- are both reserved for the plug-in definition.
    finaleplugin.RequireDocument = false
    finaleplugin.NoStore = true
    finaleplugin.HandlesUndo = true
    finaleplugin.MinJWLuaVersion = 0.68
    finaleplugin.Author = "Robert Patterson"
    finaleplugin.Copyright = "CC0 https://creativecommons.org/publicdomain/zero/1.0/"
    finaleplugin.Version = "1.0"
    finaleplugin.Date = "October 17, 2023"
    finaleplugin.Notes = [[
        If you want to execute scripts running in Trusted mode, this console script must also be
        configured as Trusted in the RGP Lua Configuration window.
    ]]
    return "RGP Lua Console...", "RGP Lua Console", "Allows immediate editing and testing of scripts in RGP Lua."
end

require('mobdebug').start()

--local variables with script-wide scope: reset each time the script is run

local file_menu             -- file menu
local in_popup_handler      -- needed because Windows calls our on_popop routine more than just for selections
local script_menu           -- script menu
local edit_text             -- text editor
local line_number_text      -- line mumbers
local output_text           -- print output area
local clear_output_chk      -- Clear Before Run checkbox

local function get_edit_text(control)
    local retval = finale.FCString()
    control:GetText(retval)
    return retval
end

local function menu_index_from_current_script()
    local script_item_index = context.selected_script_item
    assert(script_item_index > 0, "invalid script_item_index")
    assert(context.script_items_list[script_item_index], "no context for script item index")
    return script_item_index - 1 + context.first_script_in_menu
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
        local file <close> = io.open(fullpath, "r")
        if file then
            script_text = file:read("a")
        end
    end
    local script_items = finenv.CreateLuaScriptItemsFromFilePath(fullpath, script_text)
    context.original_script_text = script_text
    assert(script_items.Count > 0, "No script items returned for " .. fullpath .. ".")
    if not context.script_items_list[scripts_items_index] then
        context.script_items_list[scripts_items_index] = {}
    end
    context.script_items_list[scripts_items_index].items = script_items
    context.script_items_list[scripts_items_index].exists = file_exists
    context.selected_script_item = scripts_items_index
    edit_text:SetText(finale.FCString(script_text))
    edit_text:ResetUndoState()
    output_text:SetText(finale.FCString(""))
    script_menu:Clear()
    for item in each(script_items) do
        --local item_string = string.gsub(item.MenuItemText, "%.{3}$", "") -- remove trailing dots, if any
        script_menu:AddString(finale.FCString(item.MenuItemText))
    end
    script_menu:SetSelectedItem(0)
    local file_menu_index = scripts_items_index + context.first_script_in_menu - 1
    if file_menu_index < file_menu:GetCount() then
        file_menu:SetItemText(file_menu_index, finale.FCString(original_fullpath))
    else
        file_menu:AddString(finale.FCString(original_fullpath))
        assert(file_menu:GetCount() == file_menu_index + 1,
            "Adding string to file_menu and file_menu_index is beyond the end of it.")
    end
    file_menu:SetSelectedItem(file_menu_index)
end

local check_save -- forward reference to check_save function

local function file_new()
    if not check_save() then
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
        select_script(fc_name.LuaString, file_menu:GetCount() - context.first_script_in_menu + 1)
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
    local file <close> = io.open(file_path.LuaString, "w")
    local retval = true
    if file then
        local contents = get_edit_text(edit_text)
        file:write(contents.LuaString)
        local items = finenv.CreateLuaScriptItemsFromFilePath(file_path.LuaString, contents.LuaString)
        context.original_script_text = contents.LuaString
        assert(items.Count > 0, "no items returned for " .. file_path.LuaString)
        context.script_items_list[script_item_index].items = items
    else
        global_dialog:CreateChildUI():AlertError("Unable to write file " .. file_path.LuaString, "Save Error")
        retval = false
    end
    file_menu:SetSelectedItem(menu_index)
    return retval
end

function check_save()
    if context.selected_script_item <= 0 then
        return true -- nothing has been loaded yet if here
    end
    local fcstr = finale.FCString()
    edit_text:GetText(fcstr)
    if fcstr.LuaString ~= context.original_script_text then
        local result = global_dialog:CreateChildUI():AlertYesNo("Would you like to save your changes to this script?", "Save Changes?")
        if result == finale.YESRETURN then
            return file_save()
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

local function file_close()
    if not check_save() then
        return
    end
    local menu_index = menu_index_from_current_script()
    file_menu:DeleteItem(menu_index)
    table.remove(context.script_items_list, context.selected_script_item)
    if menu_index >= file_menu:GetCount() then
        menu_index = menu_index - 1
        assert(menu_index < file_menu:GetCount(), "menu index is out of range after deletion: " .. menu_index)
        context.selected_script_item = context.selected_script_item - 1
        if menu_index < context.first_script_in_menu then
            file_new()
            return -- file_new() sets the correct selection
        else
            assert(context.selected_script_item > 0, "context.selected_script_item has gone to zero")
            local filepath = finale.FCString()
            file_menu:GetItemText(menu_index, filepath)
            select_script(filepath.LuaString, context.selected_script_item)
        end
    else
        local filepath = finale.FCString()
        file_menu:GetItemText(menu_index, filepath)
        select_script(filepath.LuaString, context.selected_script_item)        
    end
    file_menu:SetSelectedItem(menu_index)
end

--global variables that persist (thru Lua garbage collection) until the script releases its Lua State

global_dialog = nil         -- persists thru the running of the modeless window, so reset each time the script runs

if not finenv.RetainLuaState then
    context =
    {
        tabstop_width = 4,
        output_tabstop_width = 8,
        clear_output = false,
        script_text = nil,
        original_script_text = "",
        output_text = nil,
        script_items_list = {}, -- each member is a table of 'items' (script items) and 'exists' (boolean)
        selected_script_item = 0, -- 1-based Lua index into script_items_list
        file_menu_base = { "< New >", "< Open... >", "< Save >", "< Save As... >", "< Close >", "-" },
        first_script_in_menu = 6,
        untitled_counter = 1,
        working_directory = (function()
            local str = finale.FCString()
            str:SetUserPath()
            if #str.LuaString <= 0 then
                return finenv.RunningLuaFolderPath()
            end
            return str.LuaString
        end)(),
        working_directory_valid = false,
        window_pos_x = nil,
        window_pos_y = nil
    }
    file_menu_base_handler =
    {
        file_new,
        file_open,
        file_save,
        file_save_as,
        file_close,
        function() -- nop function for divider
            file_menu:SetSelectedItem(menu_index_from_current_script())      
        end
    }
end

local function win_mac(winval, macval)
    if finenv.UI():IsOnWindows() then return winval end
    return macval
end

local function calc_tab_width(font, numchars) -- assumes fixed_width font
    local adv_points = 0
    local curr_doc = finale.FCDocument()
    if curr_doc.ID <= 0 then
        -- if no document, use hard-coded values derived from when we did have a document.
        adv_points = win_mac(4.9482421875, 6.60107421875) -- win 10pt Consolas is 5.498046875
    else
        local text_met = finale.FCTextMetrics()
        text_met:LoadString(finale.FCString("a"), font, 100)
        adv_points = text_met:GetAdvanceWidthEVPUs() / 4 -- GetAdvanceWidthPoints does not return points on Windows
    end
    return numchars * adv_points
end

local function setup_edittext_control(control, width, height, editable, tabstop_width)
    control:SetWidth(width)
    control:SetHeight(height)
    control:SetReadOnly(not editable)
    control:SetUseRichText(false)
    control:SetWordWrap(false)
    control:SetAutomaticEditing(false)
    local font = win_mac(finale.FCFontInfo("Consolas", 9), finale.FCFontInfo("Monaco", 11))
    control:SetFont(font)
    if tabstop_width then
        control:SetTabstopWidth(calc_tab_width(font, tabstop_width))
    end
    return control
end

function output_to_console(...)
    local args = { ... } -- Pack all arguments into a table
    local formatted_args = {}
    for i, arg in ipairs(args) do
        formatted_args[i] = tostring(arg)                             -- Convert each argument to a string
    end
    local formatted_string = table.concat(formatted_args, "\t") .. "\n" -- Concatenate arguments with tabs
    output_text:AppendText(finale.FCString(formatted_string))
end

function on_execution_will_start(item)
    output_to_console("Running [" .. item.MenuItemText .. "] ======>")
end

function on_execution_did_stop(item, success, msg, msgtype)
    if success then
        output_to_console("<======= ["..item.MenuItemText.."] succeeded (Processing time: 0.000 s).") -- ToDo: calculate processing time.
    else
        -- script results have already been sent to ouput by RGP Lua, so skip them
        if msgtype ~= finenv.MessageResultType.SCRIPT_RESULT then
            output_to_console(msg)
            if msgtype == finenv.MessageResultType.EXTERNAL_TERMINATION then
                output_to_console("The RGP Lua Console does not support retaining Lua state or running modeless dialogs.")
            end
        end
        output_to_console("<======= ["..item.MenuItemText.."] FAILED.")
    end
end

local function on_run_script(control)
    control:SetEnable(false)
    local script_text = get_edit_text(edit_text)
    local script_items = context.script_items_list[context.selected_script_item].items
    local x = script_items.Count
    local s = script_menu:GetSelectedItem()
    local script_item = script_items:GetItemAt(script_menu:GetSelectedItem())
    script_item.OptionalScriptText = script_text.LuaString
    script_item.AutomaticallyReportErrors = false
    script_item.Debug = true
    script_item:RegisterPrintFunction(output_to_console)
    script_item:RegisterOnExecutionWillStart(on_execution_will_start)
    script_item:RegisterOnExecutionDidStop(on_execution_did_stop)
    --script_item.Trusted = true
    if clear_output_chk:GetCheck() ~= 0 then
        output_text:SetText(finale.FCString(""))
    end
    finenv.ExecuteLuaScriptItem(script_item)
    if script_item:IsExecuting() then
        script_item:StopExecuting() -- for now, no support for modeless dialogs or RetainLuaState.
    end
    control:SetEnable(true) -- ToDo: leave it disabled if the script item is still running?
end

local function on_file_popup(control)
    local selected_item = control:GetSelectedItem()
    if in_popup_handler then
        return
    end
    in_popup_handler = true
    if selected_item < context.first_script_in_menu then
        file_menu_base_handler[selected_item + 1]()
    else
        local selected_script = selected_item - context.first_script_in_menu + 1
        if check_save() then -- check_save() may change context.first_script_in_menu
            if selected_script ~= context.selected_script_item then
                local filepath = finale.FCString()
                file_menu:GetItemText(selected_item, filepath)
                select_script(filepath.LuaString, selected_script)
            end
        end
    end
    in_popup_handler = false
end

local function on_init_window()
    for idx, str in pairsbykeys(context.file_menu_base) do
        file_menu:AddString(finale.FCString(str))
    end
    for idx, itemcontext in pairsbykeys(context.script_items_list) do
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
        select_script(context.script_items_list[context.selected_script_item].items:GetItemAt(0).FilePath, context.selected_script_item)
    end
    clear_output_chk:SetCheck(context.clear_output and 1 or 0)
    if context.script_text then
        edit_text:SetText(finale.FCString(context.script_text))
    end
    edit_text:ResetUndoState()
    if context.output_text then
        output_text:SetText(finale.FCString(""))
        output_text:AppendText(finale.FCString(context.output_text)) -- AppendText scrolls to the end
    end
    edit_text:SetKeyboardFocus()
end

local function on_close_window()
    if global_dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_ALT) or global_dialog:QueryLastCommandModifierKeys(finale.CMDMODKEY_SHIFT) then
        finenv.RetainLuaState = false
    else
        finenv.RetainLuaState = true
    end
    check_save()
    if finenv.RetainLuaState then
        context.clear_output = clear_output_chk:GetCheck() ~= 0
        context.script_text = get_edit_text(edit_text).LuaString
        context.output_text = get_edit_text(output_text).LuaString
        global_dialog:StorePosition()
        context.window_pos_x = global_dialog.StoredX
        context.window_pos_y = global_dialog.StoredY
    end 
end

local create_dialog = function()
    local dialog = finale.FCCustomLuaWindow()
    dialog:SetTitle(finale.FCString("RGP Lua - Console"))
    -- positioning parameters
    local x_separator = 10
    local y_separator = 10
    local button_width = 100
    local button_height = 20
    local edit_text_height = 280
    local output_height = edit_text_height / 2.5
    local line_number_width = 90
    local total_width = 960 -- make divisible by 3
    local curr_y = 0
    -- script selection
    file_menu = dialog:CreatePopup(0, curr_y)
    local one_third_width = total_width / 3
    file_menu:SetWidth(2*one_third_width - x_separator/2)
    script_menu = dialog:CreatePopup(total_width - one_third_width + 5, curr_y)
    script_menu:SetWidth(one_third_width - x_separator/2)
    curr_y = curr_y + button_height + y_separator
    -- editor
    line_number_text = setup_edittext_control(dialog:CreateEditText(0, curr_y), line_number_width, edit_text_height, false)
    edit_text = setup_edittext_control(dialog:CreateEditText(line_number_width + x_separator, curr_y),
        total_width - line_number_width - x_separator, edit_text_height, true, context.tabstop_width)
    curr_y = curr_y + y_separator + edit_text_height
    -- command buttons, misc.
    local run_script_cmd = dialog:CreateButton(total_width - button_width, curr_y)
    run_script_cmd:SetText(finale.FCString("Run Script"))
    run_script_cmd:SetWidth(button_width)
    dialog:RegisterHandleControlEvent(run_script_cmd, on_run_script)
    curr_y = curr_y + button_height + y_separator
    -- output console
    local output_desc = dialog:CreateStatic(0, curr_y)
    output_desc:SetWidth(100)
    output_desc:SetText(finale.FCString("Execution Output:"))
    local clear_output_chk_width = win_mac(105, 120)
    local clear_now = dialog:CreateButton(120, curr_y - win_mac(5,1))
    clear_now:SetText(finale.FCString("Clear"))
    dialog:RegisterHandleControlEvent(clear_now, function(control)
        output_text:SetText(finale.FCString(""))
    end)
    clear_output_chk = dialog:CreateCheckbox(total_width - clear_output_chk_width, curr_y)
    clear_output_chk:SetWidth(clear_output_chk_width)
    clear_output_chk:SetText(finale.FCString("Clear Before Run"))
    curr_y = curr_y + button_height
    output_text = setup_edittext_control(dialog:CreateEditText(0, curr_y), total_width, output_height, false,
        context.output_tabstop_width)
    -- close button
    local ok_btn = dialog:CreateOkButton()
    ok_btn:SetText(finale.FCString("Close"))
    -- registrations
    dialog:RegisterHandleControlEvent(file_menu, on_file_popup)
    dialog:RegisterInitWindow(on_init_window)
    dialog:RegisterCloseWindow(on_close_window)
    return dialog
end

local open_dialog = function()
    global_dialog = create_dialog()
    finenv.RegisterModelessDialog(global_dialog)
    -- For some reason we need to do this here rather than in InitWindow.
    if context.window_pos_x and context.window_pos_y then
        global_dialog:StorePosition()
        global_dialog:SetRestorePositionOnlyData(context.window_pos_x, context.window_pos_y)
        global_dialog:RestorePosition()
    end
    global_dialog:ShowModeless()
end

open_dialog()
