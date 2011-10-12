require 'io/console'

class Coolline
  if ENV["XDG_CONFIG_HOME"]
    ConfigDir   = ENV["XDG_CONFIG_HOME"]
    ConfigFile  = File.join(ConfigDir,  "coolline.rb")
  else
    ConfigDir  = ENV["HOME"]
    ConfigFile = File.join(ConfigDir, ".coolline.rb")
  end

  HistoryFile = File.join(ConfigDir, ".coolline-history")

  NullFile = "/dev/null"

  # @return [Hash] All the defaults settings
  Settings = {
    :word_boundaries => [" ", "-", "_"],

    :handlers =>
     [
      Handler.new(/\C-h|\x7F/, &:kill_backward_char),
      Handler.new("\C-a", &:beginning_of_line),
      Handler.new("\C-e", &:end_of_line),
      Handler.new("\C-k", &:kill_line),
      Handler.new("\C-f", &:forward_char),
      Handler.new("\C-b", &:backward_char),
      Handler.new("\C-d", &:kill_current_char),
      Handler.new("\C-c") { raise Interrupt },
      Handler.new("\C-w", &:kill_backward_word),
      Handler.new("\C-t", &:transpose_char),
      Handler.new("\C-n", &:next_history_line),
      Handler.new("\C-p", &:previous_history_line),
      Handler.new("\C-r", &:interactive_search),
      Handler.new("\C-a".."\C-z") {},

      Handler.new(/\e\C-h|\e\x7F/, &:kill_backward_word),
      Handler.new("\eb", &:backward_word),
      Handler.new("\ef", &:forward_word),
      Handler.new("\e[C", &:forward_char),
      Handler.new("\e[B", &:backward_char),
      Handler.new("\et", &:transpose_word),
      Handler.new("\ea".."\ez") {},
    ],

    :unknown_char_proc => :insert_string.to_proc,
    :transform_proc    => :line.to_proc,
    :completion_proc   => proc { |cool| [] },

    :history_file => HistoryFile,
    :history_size => 5000,
  }

  @config_loaded = false

  # Loads the config, even if it has already been loaded
  def self.load_config!
    if File.exist? ConfigFile
      load ConfigFile
    end

    @config_loaded = true
  end

  # Loads the config, unless it has already been loaded
  def self.load_config
    load_config! unless @config_loaded
  end

  # Creates a new cool line.
  #
  # @yieldparam [Coolline] self
  def initialize
    self.class.load_config

    @input  = STDIN # must be the actual IO object
    @output = $stdout

    self.word_boundaries   = Settings[:word_boundaries].dup
    self.handlers          = Settings[:handlers].dup
    self.transform_proc    = Settings[:transform_proc]
    self.unknown_char_proc = Settings[:unknown_char_proc]
    self.completion_proc   = Settings[:completion_proc]
    self.history_file      = Settings[:history_file]
    self.history_size      = Settings[:history_size]

    yield self if block_given?

    @history = History.new(@history_file, @history_size)
  end

  # @return [IO]
  attr_accessor :input, :output

  # @return [Array<String, Regexp>] Expressions detected as word boundaries
  attr_reader :word_boundaries

  # @return [Regexp] Regular expression to match word boundaries
  attr_reader :word_boundaries_regexp

  def word_boundaries=(array)
    @word_boundaries = array
    @word_boundaries_regexp = Regexp.union(*array)
  end

  # @return [Proc] Proc called to change the way a line is displayed
  attr_accessor :transform_proc

  # @return [Proc] Proc called to handle unmatched characters
  attr_accessor :unknown_char_proc

  # @return [Proc] Proc called to retrieve completions
  attr_accessor :completion_proc

  # @return [Array<Handler>]
  attr_accessor :handlers

  # @return [String] Name of the file containing history
  attr_accessor :history_file

  # @return [Integer] Size of the history
  attr_accessor :history_size

  # @return [History] History object
  attr_reader :history

  # @return [String] Current line
  attr_reader :line

  # @return [Integer] Cursor position
  attr_accessor :pos

  # Reads a line from the terminal
  # @param [String] prompt Characters to print before each line
  def readline(prompt = ">> ")
    @line        = ""
    @pos         = 0
    @accumulator = nil

    @history_index = @history.size
    @history_moved = false

    print "\r\e[0m\e[0K"
    print prompt

    until (char = @input.getch) == "\r"
      handle(char)

      if @history_moved
        @history_moved = false
      else
        @history_index = @history.size
      end

      width       = @input.winsize[1]
      prompt_size = strip_ansi_codes(prompt).size
      line        = transform(@line)

      stripped_line_width = strip_ansi_codes(line).size
      line << " " * [width - stripped_line_width - prompt_size, 0].max

      # reset the color, and kill the line
      print "\r\e[0m\e[0K"

      if strip_ansi_codes(prompt + line).size <= width
        print prompt + line
        print "\e[#{prompt_size + @pos + 1}G"
      else
        print prompt

        left_width = width - strip_ansi_codes(prompt).size

        start_index = [@pos - left_width + 1, 0].max
        end_index   = start_index + left_width - 1

        i = 0
        line.split(%r{(\e\[\??\d+(?:;\d+)?\w)}).each do |str|
          if start_with_ansi_code? str
            # always print ansi codes to ensure the color is right
            print str
          else
            if i >= start_index
              print str[0..(end_index - i)]
            elsif i < start_index && i + str.size >= start_index
              print str[(start_index - i), left_width]
            end

            i += str.size
            break if i >= end_index
          end
        end

        if @pos < left_width + 1
          print "\e[#{prompt_size + @pos + 1}G"
        end
      end
    end

    print "\n"

    @history << @line

    @line + "\n"
  end

  # Reads a line with no prompt
  def gets
    readline ""
  end

  # Prints objects to the output.
  def print(*objs)
    @output.print(*objs)
  end

  # Inserts a string at the current position
  # @param [String] str
  def insert_string(str)
    @line.insert @pos, str
    @pos += str.size
  end

  # Removes the previous character, if there's one
  def kill_backward_char
    if @pos != 0
      @line[@pos - 1] = ''
      @pos -= 1
    end
  end

  # Moves the cursor to the beginning of the line
  def beginning_of_line
    @pos = 0
  end

  # Moves the cursor to the end of the line
  def end_of_line
    @pos = @line.size
  end

  # Removes all the characters after the cursor
  def kill_line
    @line[@pos..-1] = ""
  end

  # Moves 1 character forward
  def forward_char
    @pos += 1 if @pos != @line.size
  end

  # Moves 1 character backward
  def backward_char
    @pos -= 1 if @pos != 0
  end

  # Removes the current character
  def kill_current_char
    @line[@pos] = "" if @pos != @line.size
  end

  # Removes the previous word
  def kill_backward_word
    if @pos != 0
      pos = @pos - 1
      pos -= 1 if pos != -1 and word_boundary? @line[pos]
      pos -= 1 until pos == -1 or word_boundary? @line[pos]
      @line[(pos + 1)..@pos] = ""
      @pos = pos + 1
    end
  end

  # Swaps the two previous characters
  def transpose_char
    if @pos >= 2
      pos = @pos == @line.size ? @pos - 1 : @pos
      @line[pos], @line[pos - 1] = @line[pos - 1], @line[pos]
    end
  end

  # Moves one word backward
  def backward_word
    if @pos != 0
      pos = @pos - 1
      pos -= 1 if pos != -1 and word_boundary? @line[pos]
      pos -= 1 until pos == -1 or word_boundary? @line[pos]
      @pos = pos + 1
    end
  end

  # Moves one word forward
  def forward_word
    if @pos != @line.size
      pos = @pos + 1
      pos += 1 if pos != @line.size and word_boundary? @line[pos]
      pos += 1 until pos == @line.size or word_boundary? @line[pos]
      @pos = pos
    end
  end

  # Swaps the two previous words
  def transpose_word
    start_pos = @pos
    pos = @pos - 1

    if pos != -1 and word_boundary? @line[pos]
      pos -= 1
      start_pos -= 1
    end

    pos -= 1 until pos == -1 or word_boundary? @line[pos]
    previous_word = @line[(pos + 1)..start_pos]

    prev_pos = pos

    if pos != -1 and word_boundary? @line[pos]
      prev_pos -= 1
      pos -= 1
    end

    pos -= 1 until pos == -1 or word_boundary? @line[pos]
    first_word = @line[(pos + 1)..prev_pos]

    if !first_word.empty? && !previous_word.empty? &&
        prev_pos >= 0 && start_pos >= 0
      @line[(pos + 1)..@pos] = "#{previous_word} #{first_word}"
    end
  end

  # Selects the previous line in history (if any)
  def previous_history_line
    if @history_index - 1 >= 0
      @line.replace @history[@history_index - 1]
      @pos = [@line.size, @pos].min

      @history_index -= 1
    end

    @history_moved = true
  end

  # Selects the next line in history (if any).
  #
  # When on the last line, this method replaces the current line with an empty
  # string.
  def next_history_line
    if @history_index + 1 <= @history.size
      @line.replace @history[@history_index + 1] || ""
      @pos = [@line.size, @pos].min

      @history_index += 1
    end

    @history_moved = true
  end

  # Prompts the user to search for a line
  def interactive_search
    initial_index = @history_index
    found_index   = @history_index

    # Use another coolline instance for the search! :D
    Coolline.new { |c|
      # Remove the search handler (to avoid nesting confusion)
      c.handlers.delete_if { |h| h.char == "\C-r" }

      # search line
      c.transform_proc = proc do
        pattern = Regexp.new Regexp.escape(c.line)

        line, found_index = @history.search(pattern, @history_index).first

        if line
          "#{c.line}): #{line}"
        else
          "#{c.line}): [pattern not found]"
        end
      end

      # Disable history
      c.history_file = NullFile
      c.history_size = 0
    }.readline("(search:")

    @line.replace @history[found_index]
    @pos = [@line.size, @pos].min

    @history_index = found_index
    @history_moved = true
  end

  private
  def transform(line)
    @transform_proc.call(line)
  end

  def handle(char)
    input = if @accumulator
              handle_escape(char)
            elsif char == "\e"
              @accumulator = "\e"
              nil
            else
              char
            end

    if input
      if handler = @handlers.find { |h| h === input }
        handler.call self
      else
        @unknown_char_proc.call self, char
      end
    end
  end

  def handle_escape(char)
    if char == "[" && @accumulator == "\e" or
        char =~ /[56]/ && @accumulator == "\e["
      @accumulator << char
      nil
    else
      str = @accumulator + char
      @accumulator = nil

      str
    end
  end

  def word_boundary?(char)
    char =~ word_boundaries_regexp
  end

  def strip_ansi_codes(string)
    string.gsub(%r{\e\[\??\d+(?:;\d+)?\w}, "")
  end

  def start_with_ansi_code?(string)
    (string =~ %r{\e\[\??\d+(?:;\d+)?\w}) == 0
  end
end
