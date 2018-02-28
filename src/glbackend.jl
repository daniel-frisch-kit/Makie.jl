using GLAbstraction, GLVisualize, GLFW
import GLWindow
const ScreenID = UInt8
const ZIndex = Int
const ScreenArea = Tuple{ScreenID, Node{IRect2D}, Node{Bool}}

struct Screen <: AbstractScreen
    glscreen::GLFW.Window
    framebuffer::GLWindow.GLFramebuffer
    rendertask::RefValue{Task}
    screen2scene::Dict{Scene, ScreenID}
    screens::Vector{ScreenArea}
    renderlist::Vector{Tuple{ZIndex, ScreenID, RenderObject}}
    cache::Dict{UInt64, RenderObject}
end
Base.isopen(x::Screen) = isopen(x.glscreen)

to_native(x::Screen) = x.glscreen

function Screen(scene::Scene; kw_args...)
    window = GLWindow.create_glcontext("Makie"; kw_args...)
    GLFW.SwapInterval(0)
    fb = GLWindow.GLFramebuffer(map(widths, scene.events.window_area))
    screen = Screen(
        window, fb,
        RefValue{Task}(),
        Dict{Scene, ScreenID}(),
        ScreenArea[],
        Tuple{ZIndex, ScreenID, RenderObject}[],
        Dict{UInt64, RenderObject}()
    )
    screen.rendertask[] = @async(renderloop(screen))
    register_callbacks(scene, to_native(screen))
    screen
end

include("glwindow.jl")


function to_glvisualize_key(k)
    k == :rotations && return :rotation
    k == :markersize && return :scale
    k == :glowwidth && return :glow_width
    k == :glowcolor && return :glow_color
    k == :strokewidth && return :stroke_width
    k == :strokecolor && return :stroke_color
    k == :positions && return :position
    k
end

function Base.push!(screen::Screen, scene::Scene, robj)
    screenid = get!(screen.screen2scene, scene) do
        id = length(screen.screens) + 1
        push!(screen.screens, (id, scene.px_area, Node(true)))
        id
    end
    push!(screen.renderlist, (0, screenid, robj))
    return robj
end

plot_key(x::Scatter) = Key{:scatter}()
plot_key(x::Lines) = Key{:lines}()

function cached_robj!(robj_func, screen, scene, x::AbstractPlot)
    robj = get!(screen.cache, object_id(x)) do
        gl_attributes = map(x.attributes) do key_value
            key, value = key_value
            gl_key = to_glvisualize_key(key)
            gl_value = map(val-> attribute_convert(val, Key{key}(), plot_key(x)), value)
            gl_key => gl_value
        end
        robj = robj_func(gl_attributes)
        for key in (:view, :projection, :resolution, :eyeposition)
            robj[key] = getfield(scene, key)
        end
        push!(screen, scene, robj)
        robj
    end
end

function Base.insert!(screen::Screen, scene::Scene, x::Scatter)
    robj = cached_robj!(screen, scene, x) do gl_attributes
        marker = popkey!(gl_attributes, :marker)
        visualize((marker, x.args), Style(:default), Dict{Symbol, Any}(gl_attributes)).children[]
    end
end

function Base.insert!(screen::Screen, scene::Scene, x::Lines)
    robj = cached_robj!(screen, scene, x) do gl_attributes
        visualize(x.args, Style(:lines), Dict{Symbol, Any}(gl_attributes)).children[]
    end
end

function addbuttons(scene::Scene, name, button, action, ::Type{ButtonEnum}) where ButtonEnum
    event = getfield(scene.events, name)
    set = event[]
    button_enum = ButtonEnum(button)
    if button != GLFW.KEY_UNKNOWN
        if action == GLFW.PRESS
            push!(set, button_enum)
        elseif action == GLFW.RELEASE
            delete!(set, button_enum)
        elseif action == GLFW.REPEAT
            # nothing needs to be done, besides returning the same set of keys
        else
            error("Unrecognized enum value for GLFW button press action: $action")
        end
    end
    event[] = set # trigger setfield event!
    return
end

"""
Returns a signal, which is true as long as the window is open.
returns `Signal{Bool}`
[GLFW Docs](http://www.glfw.org/docs/latest/group__window.html#gaade9264e79fae52bdb78e2df11ee8d6a)
"""
function window_open(scene::Scene, window::GLFW.Window)
    event = scene.events.window_open
    function windowclose(win)
        event[] = false
    end
    disconnect!(event)
    event[] = isopen(window)
    GLFW.SetWindowCloseCallback(window, windowclose)
end
function disconnect!(window::GLFW.Window, ::typeof(window_open))
    GLFW.SetWindowCloseCallback(window, nothing)
end


function window_area(scene::Scene, window)
    event = scene.events.window_area
    function windowposition(window, x::Cint, y::Cint)
        rect = event[]
        event[] = IRect(x, y, widths(rect))
    end
    function windowsize(window, w::Cint, h::Cint)
        rect = event[]
        event[] = IRect(minimum(rect), w, h)
    end
    event[] = IRect(GLFW.GetWindowPos(window), GLFW.GetFramebufferSize(window))
    disconnect!(event); disconnect!(window, window_area)
    GLFW.SetFramebufferSizeCallback(window, windowsize)
    GLFW.SetWindowPosCallback(window, windowposition)
    return
end

function disconnect!(window::GLFW.Window, ::typeof(window_area))
    GLFW.SetWindowPosCallback(window, nothing)
    GLFW.SetFramebufferSizeCallback(window, nothing)
end


"""
Registers a callback for the mouse buttons + modifiers
returns `Signal{NTuple{4, Int}}`
[GLFW Docs](http://www.glfw.org/docs/latest/group__input.html#ga1e008c7a8751cea648c8f42cc91104cf)
"""
function mouse_buttons(scene::Scene, window::GLFW.Window)
    event = scene.events.mousebuttons
    function mousebuttons(window, button, action, mods)
        addbuttons(scene, :mousebuttons, button, action, Mouse.Button)
    end
    disconnect!(event); disconnect!(window, mouse_buttons)
    GLFW.SetMouseButtonCallback(window, mousebuttons)
end
function disconnect!(window::GLFW.Window, ::typeof(mouse_buttons))
    GLFW.SetMouseButtonCallback(window, nothing)
end
function keyboard_buttons(scene::Scene, window::GLFW.Window)
    event = scene.events.keyboardbuttons
    function keyoardbuttons(window, button::Cint, scancode::Cint, action::Cint, mods::Cint)
        addbuttons(scene, :keyboardbuttons, button, action, Keyboard.Button)
    end
    disconnect!(event); disconnect!(window, keyboard_buttons)
    GLFW.SetKeyCallback(window, keyoardbuttons)
end

function disconnect!(window::GLFW.Window, ::typeof(keyboard_buttons))
    GLFW.SetKeyCallback(window, nothing)
end

"""
Registers a callback for drag and drop of files.
returns `Signal{Vector{String}}`, which are absolute file paths
[GLFW Docs](http://www.glfw.org/docs/latest/group__input.html#gacc95e259ad21d4f666faa6280d4018fd)
"""
function dropped_files(scene::Scene, window::GLFW.Window)
    event = scene.events.dropped_files
    function droppedfiles(window, files)
        event[] = String.(files)
    end
    disconnect!(event); disconnect!(window, dropped_files)
    event[] = String[]
    GLFW.SetDropCallback(window, droppedfiles)
end
function disconnect!(window::GLFW.Window, ::typeof(dropped_files))
    GLFW.SetDropCallback(window, nothing)
end


"""
Registers a callback for keyboard unicode input.
returns an `Signal{Vector{Char}}`,
containing the pressed char. Is empty, if no key is pressed.
[GLFW Docs](http://www.glfw.org/docs/latest/group__input.html#ga1e008c7a8751cea648c8f42cc91104cf)
"""
function unicode_input(scene::Scene, window::GLFW.Window)
    event = scene.events.unicode_input
    function unicodeinput(window, c::Char)
        vals = event[]
        push!(vals, c)
        event[] = vals
        empty!(vals)
        event[] = vals
    end
    disconnect!(event); disconnect!(window, unicode_input)
    x = Char[]; sizehint!(x, 1)
    event[] = x
    GLFW.SetCharCallback(window, unicodeinput)
end
function disconnect!(window::GLFW.Window, ::typeof(unicode_input))
    GLFW.SetCharCallback(window, nothing)
end

# TODO memoise? Or to bug ridden for the small performance gain?
function retina_scaling_factor(w, fb)
    (w[1] == 0 || w[2] == 0) && return (1.0, 1.0)
    fb ./ w
end
function retina_scaling_factor(window::GLFW.Window)
    w, fb = GLFW.GetWindowSize(window), GLFW.GetFramebufferSize(window)
end

function correct_mouse(window::GLFW.Window, w, h)
    ws, fb = GLFW.GetWindowSize(window), GLFW.GetFramebufferSize(window)
    s = retina_scaling_factor(ws, fb)
    (w, fb[2] - h) .* s
end

"""
Registers a callback for the mouse cursor position.
returns an `Signal{Vec{2, Float64}}`,
which is not in scene coordinates, with the upper left window corner being 0
[GLFW Docs](http://www.glfw.org/docs/latest/group__input.html#ga1e008c7a8751cea648c8f42cc91104cf)
"""
function mouse_position(scene::Scene, window::GLFW.Window)
    event = scene.events.mouseposition
    function cursorposition(window, w::Cdouble, h::Cdouble)
        event[] = correct_mouse(window, w, h)
    end
    disconnect!(event); disconnect!(window, mouse_position)
    event[] = correct_mouse(window, GLFW.GetCursorPos(window)...)
    GLFW.SetCursorPosCallback(window, cursorposition)
end
function disconnect!(window::GLFW.Window, ::typeof(mouse_position))
    GLFW.SetCursorPosCallback(window, nothing)
end

"""
Registers a callback for the mouse scroll.
returns an `Signal{Vec{2, Float64}}`,
which is an x and y offset.
[GLFW Docs](http://www.glfw.org/docs/latest/group__input.html#gacc95e259ad21d4f666faa6280d4018fd)
"""
function scroll(scene::Scene, window::GLFW.Window)
    event = scene.events.scroll
    function scrollcb(window, w::Cdouble, h::Cdouble)
        event[] = (w, h)
        event[] = (0.0, 0.0)
    end
    disconnect!(event); disconnect!(window, scroll)
    event[] = (0.0, 0.0)
    GLFW.SetScrollCallback(window, scrollcb)
end
function disconnect!(window::GLFW.Window, ::typeof(scroll))
    GLFW.SetScrollCallback(window, nothing)
end

"""
Registers a callback for the focus of a window.
returns an `Signal{Bool}`,
which is true whenever the window has focus.
[GLFW Docs](http://www.glfw.org/docs/latest/group__window.html#ga6b5f973531ea91663ad707ba4f2ac104)
"""
function hasfocus(scene::Scene, window::GLFW.Window)
    event = scene.events.hasfocus
    function hasfocuscb(window, focus::Bool)
        event[] = focus
    end
    disconnect!(event); disconnect!(window, hasfocus)
    event[] = false
    GLFW.SetWindowFocusCallback(window, hasfocuscb)
end
function disconnect!(window::GLFW.Window, ::typeof(hasfocus))
    GLFW.SetWindowFocusCallback(window, nothing)
end

"""
Registers a callback for if the mouse has entered the window.
returns an `Signal{Bool}`,
which is true whenever the cursor enters the window.
[GLFW Docs](http://www.glfw.org/docs/latest/group__input.html#ga762d898d9b0241d7e3e3b767c6cf318f)
"""
function entered_window(scene::Scene, window::GLFW.Window)
    event = scene.events.entered_window
    function enteredwindowcb(window, focus::Bool)
        event[] = focus
    end
    disconnect!(event); disconnect!(window, entered_window)
    event[] = false
    GLFW.SetCursorEnterCallback(window, enteredwindowcb)
end

function disconnect!(window::GLFW.Window, ::typeof(entered_window))
    GLFW.SetCursorEnterCallback(window, nothing)
end
