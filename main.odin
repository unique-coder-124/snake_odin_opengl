package main

import "core:fmt"
import "core:time"
import "core:math"
import "core:math/rand"
import "vendor:glfw"
import gl "vendor:OpenGL"
import "core:os"
import "base:runtime"


// vector used for position and velocity
vec2 :: [2]i32

// represents the different tile types
tile :: enum {
  BG, // background
  OB, // obstacle
  SN, // snake
  HD, // head
  FD, // food
}

// calculates index of 1d array that represents 2d grid
calc_game_idx :: proc(vector2d: vec2, grid_w : i32) -> (result: i32) {
  result = vector2d.y * grid_w + vector2d.x
  return
}

draw_tile_pos :: proc(start_index: i32, pos_x, pos_y: f32) {
  gl.Uniform1f(gl.GetUniformLocation(global_shader, "pos_x"), pos_x)
  gl.Uniform1f(gl.GetUniformLocation(global_shader, "pos_y"), pos_y)

  gl.BindVertexArray(global_vao)
  defer gl.BindVertexArray(0)

  gl.DrawElements(gl.TRIANGLES,                                     // Draw triangles
                  6,                                                // Number of indices (2 triangles * 3 vertices each)
                  gl.UNSIGNED_INT,                                  // Type of indices
                  rawptr(uintptr(start_index * 6 * size_of(u32))))  // set offset
}

// overload to check if position in position vector of unknown/dynamic size
vec2_in_dynamic :: proc(vector2d: vec2, arr: [dynamic]vec2) -> (bool) {
  for value in arr {
    if vector2d == value {
      return true
    }
  }
  return false
}

// overload to check if position in position vector of unknown size as slice
vec2_in_arr :: proc(vector2d: vec2, arr: []vec2) -> (bool) {
  for value in arr {
    if vector2d == value {
      return true
    }
  }
  return false
}

// overloaded function for automatic routing
vec2_in_list :: proc{vec2_in_dynamic, vec2_in_arr}

// Quit the window if the ESC key is pressed. This procedure is called by
// glfw.SetKeyCallback.
callback_key :: proc "c" ( window : glfw.WindowHandle, key, scancode, action, mods : i32 ) {
  if action == glfw.PRESS {
    if key == glfw.KEY_ESCAPE {
      glfw.SetWindowShouldClose(window, true)
    }
    switch key {
      case glfw.KEY_W, glfw.KEY_UP:
        // set move direction up
        snake_velocity = {0, -1} if prev_snake_velocity != {0, +1} else snake_velocity
      case glfw.KEY_A, glfw.KEY_LEFT:
        // set move direction left
        snake_velocity = {-1, 0} if prev_snake_velocity != {+1, 0} else snake_velocity
      case glfw.KEY_S, glfw.KEY_DOWN:
        // set move direction down
        snake_velocity = {0, +1} if prev_snake_velocity != {0, -1} else snake_velocity
      case glfw.KEY_D, glfw.KEY_RIGHT:
        // set move direction right
        snake_velocity = {+1, 0} if prev_snake_velocity != {-1, 0} else snake_velocity
    }
  }
  switch key {
    case glfw.KEY_SPACE:
      // activate dash ability if dash cooldown ended
      if dash_cooldown == 0 {
        snake_dash = true
        dash_cooldown = dash_cooldown_const
      }
  }
}

// If the window needs to be redrawn (e.g. the user resizes the window), redraw the window.
// This procedure is called by  glfw.SetWindowRefreshCallback.
window_refresh :: proc "c" ( window : glfw.WindowHandle ) {
  context = runtime.default_context()
  w, h: i32
  w, h = glfw.GetFramebufferSize(window)
  gl.Viewport(0, 0, w, h)

  fw := cast(f32)w
  fh := cast(f32)h

  f_border_w_px := cast(f32)border_width_pixels
  f_border_h_px := cast(f32)border_height_pixels

  // Calculate usable dimensions in pixels (inside the border)
  usable_w_px := fw - 2.0 * f_border_w_px
  usable_h_px := fh - 2.0 * f_border_h_px

  // Ensure usable dimensions are not negative
  if usable_w_px < 0 { usable_w_px = 0 }
  if usable_h_px < 0 { usable_h_px = 0 }

  // Calculate pixel size of one tile (assuming square tiles for simplicity of fitting the grid)
  // to fit within the usable area while maintaining aspect ratio of the grid.
  tile_s_px_based_on_width  := usable_w_px / cast(f32)grid_w
  tile_s_px_based_on_height := usable_h_px / cast(f32)grid_h
  actual_tile_s_px          := math.min(tile_s_px_based_on_width, tile_s_px_based_on_height)
  if actual_tile_s_px < 0 { actual_tile_s_px = 0 } // Prevent negative size

  // Update global tile_w and tile_h (these are NDC dimensions of one tile)
  // These are used in the `vertices` array construction.
  // The VBO expects these to be the actual dimensions of a single tile in NDC.
  tile_w = (actual_tile_s_px / fw) * 2.0 // tile_w is global
  tile_h = (actual_tile_s_px / fh) * 2.0 // tile_h is global

  // Total NDC size of the rendered grid
  rendered_grid_ndc_w := tile_w * cast(f32)grid_w
  rendered_grid_ndc_h := tile_h * cast(f32)grid_h

  // NDC offsets for borders (from -1 or 1 edge of screen)
  border_ndc_x_from_edge := (f_border_w_px / fw) * 2.0
  border_ndc_y_from_edge := (f_border_h_px / fh) * 2.0

  // NDC width/height of the drawable area (inside borders)
  drawable_area_ndc_w := (usable_w_px / fw) * 2.0
  drawable_area_ndc_h := (usable_h_px / fh) * 2.0
  
  // Calculate centering gap within the drawable area
  gap_x_ndc := drawable_area_ndc_w - rendered_grid_ndc_w
  gap_y_ndc := drawable_area_ndc_h - rendered_grid_ndc_h

  // Target top-left corner of the grid in full NDC
  target_grid_TL_x_ndc := -1.0 + border_ndc_x_from_edge + gap_x_ndc / 2.0
  target_grid_TL_y_ndc :=  1.0 - border_ndc_y_from_edge - gap_y_ndc / 2.0

  // Update global offset_x, offset_y.
  // These represent the shift required from the VBO's default (-1,1) anchor point
  // for the (0,0) tile of the grid to achieve the target_grid_TL position.
  offset_x = target_grid_TL_x_ndc - (-1.0) // offset_x is global
  offset_y = (1.0 - target_grid_TL_y_ndc) // offset_y is global

  vertices = {
    // Coordinates ; Colors
    // food
    -1 + tile_w, 1,           1, 0, 0,
    -1 + tile_w, 1 - tile_h,  1, 0, 0,
    -1, 1,                    1, 0, 0,
    -1, 1 - tile_h,           1, 0, 0,
    // snake
    -1 + tile_w, 1,           0, 1, 0,
    -1 + tile_w, 1 - tile_h,  0, 1, 0,
    -1, 1,                    0, 1, 0,
    -1, 1 - tile_h,           0, 1, 0,
    // wall
    -1 + tile_w, 1,           144.0/255, 144.0/255, 144.0/255,
    -1 + tile_w, 1 - tile_h,  144.0/255, 144.0/255, 144.0/255,
    -1, 1,                    144.0/255, 144.0/255, 144.0/255,
    -1, 1 - tile_h,           144.0/255, 144.0/255, 144.0/255,
    // head
    -1 + tile_w, 1,           144.0/255, 0, 1,
    -1 + tile_w, 1 - tile_h,  144.0/255, 0, 1,
    -1, 1,                    144.0/255, 0, 1,
    -1, 1 - tile_h,           144.0/255, 0, 1,
  }

  gl.BindBuffer(gl.ARRAY_BUFFER, global_vbo)
  gl.BufferSubData(gl.ARRAY_BUFFER, 0, size_of(vertices), &vertices);
}

// Create alias types for vertex array / buffer objects
VAO :: u32
VBO :: u32
EBO :: u32
ShaderProgram :: u32

// Global variables.
global_vao: VAO
global_vbo: VBO
global_ebo: EBO
global_shader: ShaderProgram

grid_w :: 50
grid_h :: 40

/*  methods choose size of window and grid tiles  */
/*  -----------------------------------------------  */
// method 1
// tile_s :: 40
// window_w :: tile_s * grid_w / 2
// window_h :: tile_s * grid_h / 2

// method 2
window_w :: 1000
window_h :: 800
tile_s :: min(2*window_w/grid_w, 2*window_h/grid_h)
/*  -----------------------------------------------  */

tile_w: f32 = f32(tile_s)/window_w
tile_h: f32 = f32(tile_s)/window_h

border_width_pixels :: 20 // Example: 20 pixels border on each side
border_height_pixels :: 20 // Example: 20 pixels border on top/bottom

offset_x : f32 = 0
offset_y : f32 = 0

snake_game: [grid_w * grid_h]tile                 // array of tiles representing game board
snake_head: vec2 = {grid_w/2, grid_h/2}           // position of head
snake := make([dynamic]vec2, 0, grid_w * grid_h)  // body tiles of snake
velocity :: 20.0                                  // position updates per second
snake_dash: bool = false                          // flag for snake block skip abiliy
dash_cooldown_const :: 5                          // position updates until next dash
dash_cooldown: int = 0                            // initial dash cooldown
snake_velocity: vec2 = {1, 0}                     // direction of snake
prev_snake_velocity: vec2 = {1, 0}                // old snake velocity to check valid move directions
lost_game: bool = false                           // lost game flag /* TODO: add game-over screen */
food_pos: vec2 = snake_head                       // initial food position on head to increase length by one for +1 start length

vertices : [80] f32 = {
  // Coordinates ; Colors
  // food
  -1 + tile_w, 1,           1, 0, 0,
  -1 + tile_w, 1 - tile_h,  1, 0, 0,
  -1, 1,                    1, 0, 0,
  -1, 1 - tile_h,           1, 0, 0,
  // snake
  -1 + tile_w, 1,           0, 1, 0,
  -1 + tile_w, 1 - tile_h,  0, 1, 0,
  -1, 1,                    0, 1, 0,
  -1, 1 - tile_h,           0, 1, 0,
  // wall
  -1 + tile_w, 1,           144.0/255, 144.0/255, 144.0/255,
  -1 + tile_w, 1 - tile_h,  144.0/255, 144.0/255, 144.0/255,
  -1, 1,                    144.0/255, 144.0/255, 144.0/255,
  -1, 1 - tile_h,           144.0/255, 144.0/255, 144.0/255,
  // head
  -1 + tile_w, 1,           144.0/255, 0, 1,
  -1 + tile_w, 1 - tile_h,  144.0/255, 0, 1,
  -1, 1,                    144.0/255, 0, 1,
  -1, 1 - tile_h,           144.0/255, 0, 1,
}

indices: [24] u32 = {
  // Coordinates ; Colors
  // food
  0,  1,  2,
  1,  3,  2,
  // snake
  4,  5,  6,
  5,  7,  6,
  // wall
  8,  9,  10,
  9,  11, 10,
  // head
  12, 13, 14,
  13, 15, 14,
}

// hard coded obstacles in corner arrows
obst: [12]vec2 = {{0, 0}, {1, 0}, {0, 1},
  {grid_w - 1, 0}, {grid_w - 2, 0}, {grid_w - 1, 1},
  {0, grid_h - 1}, {0, grid_h - 2}, {1, grid_h - 1},
  {grid_w - 1, grid_h - 1}, {grid_w - 2, grid_h - 1}, {grid_w - 1, grid_h - 2}}

main :: proc() {
  defer delete(snake)

  // Setup window, including priming for OpenGL 3.3.
  glfw.Init()
  defer glfw.Terminate()

  glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
  glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
  glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

  window := glfw.CreateWindow(window_w, window_h, "odin snake game", nil, nil)
  assert(window != nil)
  defer glfw.DestroyWindow(window)

  glfw.MakeContextCurrent(window)
  glfw.SwapInterval(1)

  // Load OpenGL 3.3 function pointers.
  gl.load_up_to(3,3, glfw.gl_set_proc_address)

  // Key press / Window-resize behaviour
  glfw.SetKeyCallback(window, callback_key)
  glfw.SetWindowRefreshCallback(window, window_refresh)

  w, h := glfw.GetFramebufferSize(window)
  gl.Viewport(0,0,w,h)

  // Set up vertex array/buffer objects.
  gl.GenVertexArrays(1, &global_vao)
  gl.BindVertexArray(global_vao)

  gl.GenBuffers(1, &global_vbo)
  gl.BindBuffer(gl.ARRAY_BUFFER, global_vbo)

  // Describe GPU buffer.
  gl.BufferData(gl.ARRAY_BUFFER,     // target
                size_of(vertices),   // size of the buffer object's data store
                &vertices,           // data used for initialization
                gl.STATIC_DRAW)      // usage

  gl.GenBuffers(1, &global_ebo)
  gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, global_ebo)

  // Describe GPU buffer.
  gl.BufferData(gl.ELEMENT_ARRAY_BUFFER,    // target
                size_of(indices),           // size of the buffer object's data store
                &indices,                   // data used for initialization
                gl.STATIC_DRAW)             // usage

  // Position and color attributes. Don't forget to enable!
  gl.VertexAttribPointer(0,                // index
                         2,                // size
                         gl.FLOAT,         // type
                         gl.FALSE,         // normalized
                         5 * size_of(f32), // stride
                         0)                // offset

  // color information
  gl.VertexAttribPointer(1,                // index      
                         3,                // size
                         gl.FLOAT,         // type
                         gl.FALSE,         // normalized
                         5 * size_of(f32), // stride
                         2 * size_of(f32)) // offset

  // Enable the vertex position and color attributes defined above.
  gl.EnableVertexAttribArray(0)
  gl.EnableVertexAttribArray(1)

  // Compile vertex shader and fragment shader.
  // Note how much easier this is in Odin than in C++!

  program_ok: bool
  vertex_shader := string(#load("vertex.glsl"))
  fragment_shader := string(#load("fragment.glsl"))

  global_shader, program_ok = gl.load_shaders_source(vertex_shader, fragment_shader);

  if !program_ok {
    fmt.println("ERROR: Failed to load and compile shaders."); os.exit(1)
  }

  gl.UseProgram(global_shader)

  // initialises time keeping variables
  start: i64 = time.now()._nsec
  end: i64 = time.now()._nsec
  delta_sum: f64
  delta_time: f64

  window_refresh(window)

  // main update_loop
  game_loop : for !glfw.WindowShouldClose(window) {
    glfw.PollEvents()

    // delta time calculations
    end = time.now()._nsec
    delta_time = f64(end - start) / math.pow10_f64(9)
    start = time.now()._nsec
    delta_sum += delta_time

    // calculates movement and grows snake
    if delta_sum >= 1.0/velocity {
      append(&snake, snake_head)
      if snake_head != food_pos {
        // by only removing when food not in head
        // we increase length by not removing when
        // head and food are in the same position
        ordered_remove(&snake, 0)
      } else {
        // keep trying random positions until a valid food position is found
        /* NOTE: when snake length is long this becomes less efficient */
        for (food_pos == snake_head) || (vec2_in_list(food_pos, snake)) || (vec2_in_list(food_pos, obst[:])) {
          food_pos = {rand.int31_max(grid_w), rand.int31_max(grid_h)}
        }
      }

      // move snake head and if dash is true then skip a square
      // wrap snake around borders when index goes beyond grid size
      snake_head.x += 2 * snake_velocity.x if snake_dash else snake_velocity.x
      if snake_head.x >= grid_w {
        snake_head.x %= grid_w
      } else if snake_head.x <= 0 {
        snake_head.x %%= grid_w
      }
      snake_head.y += 2 * snake_velocity.y if snake_dash else snake_velocity.y
      if snake_head.y >= grid_h {
        snake_head.y %= grid_h
      } else if snake_head.y <= 0 {
        snake_head.y %%= grid_h
      }
      // disable dash and wait for next cooldown
      snake_dash = false
      // set previous velocity to avoid invalid move directions on next iteration
      prev_snake_velocity = snake_velocity
      // reduce dash cooldown by 1 for move update unless at munimum value
      dash_cooldown -= 1 if dash_cooldown > 0 else 0

      // reduce delta sum (time since last move update) by desired period between move updates
      /* NOTE: averages framerate over time */
      delta_sum -= 1.0/velocity
      when ODIN_DEBUG {
        // print framerate (abs frame rate not move frame rate as move frame rate defined average == velocity)
        fmt.println(1/delta_time)
      }
    }

    // clear game grid
    for &tile_seg in snake_game {
      tile_seg = tile.BG
    }

    // add snake segments to game_grid
    for seg_idx in 0..<(len(snake)) {
      if snake[seg_idx] == snake_head {
        // check for snake head collision and set lose game to true
        /* TODO: add game ove screen */
        lost_game = true
      }
      snake_game[calc_game_idx(snake[seg_idx], grid_w)] = tile.SN
    }

    // add wall segments to game_grid
    for seg_idx in 0..<(len(obst)) {
      if obst[seg_idx] == snake_head {
        // check for obstacle head collision and set lose game to true
        /* TODO: add game ove screen */
        lost_game = true
      }
      snake_game[calc_game_idx(obst[seg_idx], grid_w)] = tile.OB
    }

    // add snake head to game_grid
    snake_game[calc_game_idx(snake_head, grid_w)] = tile.HD

    // add food to game grid
    snake_game[calc_game_idx(food_pos, grid_w)] = tile.FD

    // draw colour tile based on tile type
    for y_idx: f32 = 0; y_idx < grid_h; y_idx += 1 {
      for x_idx: f32; x_idx < grid_w; x_idx += 1 {
        switch snake_game[calc_game_idx({i32(x_idx), i32(y_idx)}, grid_w)] {
          // draw rect of certain colour for each grid segment
          case .BG:
          case .OB:
            draw_tile_pos(2, x_idx * tile_w + offset_x, y_idx * tile_h + offset_y)
          case .SN:
            draw_tile_pos(1, x_idx * tile_w + offset_x, y_idx * tile_h + offset_y)
          case .HD:
            draw_tile_pos(3, x_idx * tile_w + offset_x, y_idx * tile_h + offset_y)
          case .FD:
            draw_tile_pos(0, x_idx * tile_w + offset_x, y_idx * tile_h + offset_y)
        }
      }
    }

    glfw.SwapBuffers(window)

    // Draw commands.
    gl.ClearColor(0.0, 0.0, 0.0, 1)
    gl.Clear(gl.COLOR_BUFFER_BIT)

    // end game
    /* TODO: add gameover screen */
    if lost_game {
      break game_loop
    }
  }
}

