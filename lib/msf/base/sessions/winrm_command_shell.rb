# -*- coding: binary -*-

require 'winrm'

module Msf::Sessions
  #
  # This class provides a session for WinRM client connections, where Metasploit
  # has authenticated to a remote WinRM instance.
  #
  class WinrmCommandShell < Msf::Sessions::CommandShell

    # Abstract WinRM to look like a stream so CommandShell can be happy
    class WinRMStreamAdapter
      # @param shell [Net::MsfWinRM::StdinShell] Shell for talking to the WinRM service
      # @param on_shell_ended [Method] Callback for when the background thread notices the shell has ended
      def initialize(shell, on_shell_ended)
        # To buffer input received while a session is backgrounded, we stick responses in a list
        @buffer_mutex = Mutex.new
        @buffer = []
        @check_stdin_event = Rex::Sync::Event.new(false, true)
        @received_stdout_event = Rex::Sync::Event.new(false, true)
        self.shell = shell
        self.on_shell_ended = on_shell_ended
      end

      def peerinfo
        shell.transport.peerinfo
      end

      def localinfo
        shell.transport.localinfo
      end

      def refresh_stdout
        @check_stdin_event.set
      end

      def write(buf)
        shell.send_stdin(buf)
        refresh_stdout
      end

      ##
      # :category: Msf::Session::Provider::SingleCommandShell implementors
      #
      # Read from the command shell.
      #
      def get_once(length = -1, _timeout = 1)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
        result = ""
        loop do
          result = _get_once(length)
          time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
          elapsed = time - start_time
          time_remaining = _timeout - elapsed
          break if (result != '' || time_remaining <= 0)
          begin
            @received_stdout_event.wait(time_remaining)
          rescue TimeoutError

          end
          # If we didn't get anything, let's hurry the background thread along
          refresh_stdout unless result
        end
        result
      end

      def _get_once(length)
        result = ''
        @buffer_mutex.synchronize do
          result = @buffer.join('')
          @buffer = []
          if (length > -1) && (result.length > length)
            # Return up to length, and keep the rest in the buffer
            extra = result[length..-1]
            result = result[0, length]
            @buffer << extra
          end
        end
        result
      end

      def start_keep_alive_loop(framework)
        self.keep_alive_thread = framework.threads.spawn('WinRM-shell-keepalive', false, shell) do |_thr_shell|
          loop_delay = 0.5
          loop do
            tmp_buffer = []
            output_seen = false
            shell.read_stdout do |stdout, stderr|
              if stdout || stderr
                output_seen = true
              end
              tmp_buffer << stdout if stdout
              tmp_buffer << stderr if stderr
            end
            @buffer_mutex.synchronize do
              @buffer.concat(tmp_buffer)
            end

            # If our last request received stdout, let's be ready for some more
            if output_seen
              @received_stdout_event.set
              loop_delay = 0.5
            else
              # Gradual backoff
              loop_delay *= 4
              loop_delay = [loop_delay, 30].min
            end

            # Wait loop_delay seconds, or until an interactive thread wakes us up
            begin
              @check_stdin_event.wait(loop_delay)
              # rubocop:disable Lint/SuppressedException
            rescue TimeoutError
            end
            # rubocop:enable Lint/SuppressedException
            Thread.pass
          rescue WinRM::WinRMWSManFault => e
            print_error(e.fault_description)
            on_shell_ended.call
          rescue EOFError
            # Shell has been terminated
            on_shell_ended.call
          rescue Rex::HostUnreachable => e
            on_shell_ended.call(e.message)
          rescue StandardError => e
            on_shell_ended.call(e.message)
          end
        end
      end

      def stop_keep_alive_loop
        keep_alive_thread.kill
      end

      def close
        stop_keep_alive_loop
        shell.cleanup_shell
      rescue WinRM::WinRMWSManFault
      end

      attr_accessor :shell, :keep_alive_thread, :on_shell_ended

    end

    def commands
      {
        'help' => 'Help menu',
        'background' => 'Backgrounds the current shell session',
        'sessions' => 'Quickly switch to another session',
        'resource' => 'Run a meta commands script stored in a local file',
        'irb' => 'Open an interactive Ruby shell on the current session',
        'pry' => 'Open the Pry debugger on the current session'
      }
    end

    #
    # Create an MSF command shell from a WinRM shell object
    #
    # @param shell [WinRM::Shells::Base] A WinRM shell object
    # @param opts [Hash] Optional parameters to pass to the session object.
    def initialize(shell, opts = {})
      self.shell = shell
      self.adapter = WinRMStreamAdapter.new(self.shell, method(:shell_ended))
      super(adapter, opts)
    end

    def abort_foreground_supported
      true
    end

    def abort_foreground
      shell.send_ctrl_c
      adapter.refresh_stdout
    end

    def command_termination
      "\r\n"
    end

    ##
    # :category: Msf::Session::Interactive implementors
    #
    def _interact_stream
      fds = [user_input.fd]
      while interacting
        sd = Rex::ThreadSafe.select(fds, nil, fds, 0.5)
        begin
          user_output.print(shell_read(-1, 0))
          if sd
            run_single((user_input.gets || '').chomp("\n"))
          end
        rescue WinRM::WinRMWSManFault => e
          print_error(e.fault_description)
          shell_close
        end
        Thread.pass
      end
    end

    def on_registered
      adapter.start_keep_alive_loop(framework)
    end

    def shell_ended(reason = '')
      self.interacting = false
      framework.events.on_session_interact_completed
      framework.sessions.deregister(self, reason)
    end

    protected

    attr_accessor :shell, :adapter

  end
end
