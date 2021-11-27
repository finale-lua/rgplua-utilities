function plugindef()
    -- This function and the 'finaleplugin' namespace
    -- are both reserved for the plug-in definition.
    finaleplugin.RequireDocument = false
    finaleplugin.NoStore = true
    finaleplugin.HandlesUndo = true
    finaleplugin.Author = "Robert Patterson"
    finaleplugin.Copyright = "CC0 https://creativecommons.org/publicdomain/zero/1.0/"
    finaleplugin.Version = "1.0"
    finaleplugin.Date = "November 27, 2021"
    return "RGP Lua Class Browser", "RGP Lua Class Browser", "RGP Lua Class Browser"
end

-- require('mobdebug').start() -- uncomment this to debug

eligible_classes = {}
for k, v in pairs(_G.finale) do
    local kstr = tostring(k)
    if kstr:find("FC") == 1  then
        eligible_classes[kstr] = 1
    end    
end

search_classes_text = nil
search_properties_text = nil
search_methods_text = nil

classes_list = nil
properties_list = nil
methods_list = nil
class_methods_list = nil

local update_lists = function(search_text)
    classes_list:Clear()
    if search_text == nil or search_text == "" then
        search_text = "FC"
    end
    for k, _ in pairsbykeys(eligible_classes) do
        if k:find(search_text) == 1  then
            local fcstring = finale.FCString()
            fcstring.LuaString = k;
            classes_list:AddString(fcstring)
        end
    end
end

local create_dialog = function()
    local x = 0
    local y = 0
    local col_width = 160
    local sep_width = 30
    local vert_sep = 25
    
    local create_edit = function(dialog)
        local edit_text = dialog:CreateEdit(x, y)
        edit_text:SetWidth(col_width)
        x = x + col_width + sep_width
        return edit_text
    end
    
    local create_static = function(dialog, text)
        local static_text = dialog:CreateStatic(x, y)
        local fcstring = finale.FCString()
        fcstring.LuaString = text
        static_text:SetWidth(col_width)
        static_text:SetText(fcstring)
        x = x + col_width + sep_width
        return static_text
    end
    
    local create_list = function(dialog, height)
        local list = dialog:CreateListBox(x, y)
        list:SetWidth(col_width)
        list:SetHeight(height)
        x = x + col_width + sep_width
        return list
    end

    -- scratch FCString
    local str = finale.FCString()
    -- create a new dialog
    local dialog = finale.FCCustomLuaWindow()
    str.LuaString = "RGP Lua - Class Browser"
    dialog:SetTitle(str)
    
    -- create search fields
    search_classes_text = create_edit(dialog)
    dialog:RegisterHandleControlEvent(
        search_classes_text,
        function(control)
            local str = finale.FCString()
            control:GetText(str)
            update_lists(str.LuaString)
        end
    )
    
    search_properties_text = create_edit(dialog)
    search_methods_text = create_edit(dialog)
    
    -- create headers
    x = 0
    y = y + vert_sep
    create_static(dialog, "Classes:")
    create_static(dialog, "Properties:")
    create_static(dialog, "Methods:")
    create_static(dialog, "Class Methods:")
    
    -- create lists
    x = 0
    y = y + vert_sep
    classes_list = create_list(dialog, 450)
    properties_list = create_list(dialog, 200)
    methods_list = create_list(dialog, 200)
    class_methods_list = create_list(dialog, 200)
    
    -- create close button
    local ok_button = dialog:CreateOkButton()
    str.LuaString = "Close"
    ok_button:SetText(str)
    return dialog
end

local open_dialog = function()
    local dialog = create_dialog()
    update_lists()
    finenv.RegisterModelessDialog(dialog)
    dialog:ShowModeless()
end

open_dialog()

