require "crystal/digest/md5"
require "compress/gzip"

module Crystal
  module Build
    ByteFormat = IO::ByteFormat::LittleEndian

    struct Result
      getter result
      getter recursive_buildtime_dependencies
      getter modification_time

      def initialize(@result : String, @recursive_buildtime_dependencies = Set(String).new, @modification_time = Time.utc)
        File.info(@result) # Check if result exists
      end

      protected def self.write_string(value, io)
        bytes = value.to_slice
        ByteFormat.encode(UInt16.new(bytes.size), io)
        io.write(bytes)
      end

      protected def self.read_string(io)
        size = ByteFormat.decode(UInt16, io)
        bytes = Bytes.new(size)
        io.read(bytes)
        String.new(bytes)
      end

      def write(io : IO)
        Result.write_string(@result, io)
        ByteFormat.encode(UInt16.new(@recursive_buildtime_dependencies.size), io)
        @recursive_buildtime_dependencies.each do |d|
          Result.write_string(d, io)
        end
      end

      def self.read(io : IO, modification_time = Time.utc)
        result = read_string(io)
        recursive_buildtime_dependencies = Set(String).new
        ByteFormat.decode(UInt16, io).times.each do
          recursive_buildtime_dependencies.add(read_string(io))
        end
        self.new(result, recursive_buildtime_dependencies, modification_time)
      end
    end

    alias Dependency = Job | String
    alias ResultOrException = Result | Exception
    alias BlockResult = Result | String
    alias Dependencies = Array(Dependency) | Array(Job) | Array(String)

    abstract class Policy
      property n_threads = 1

      def rebuild_required?(job : Job) : Bool
        return true
      end
    end

    class AlwaysBuildPolicy < Policy
      def rebuild_required?(job : Job) : Bool
        return true
      end
    end

    class ModificationTimeBuildPolicy < Policy
      def rebuild_required?(job : Job) : Bool
        begin
          modification_time = job.modification_time
          (job.recursive_dependencies + job.recursive_buildtime_dependencies).each do |d|
            dmtime = File.info(d).modification_time
            return true if dmtime > modification_time
          end
        rescue File::NotFoundError
          return true
        end
        return false
      end
    end

    class Job
      @result : ResultOrException?
      @last_result : Result?
      @recursive_dependencies : Set(String)

      getter recursive_dependencies

      def initialize(@name : String, @outdir : String, flags = [] of String, @dependencies : Dependencies = Array(Dependency).new, &block : Array(String) -> BlockResult)
        @block = block
        @result = nil
        @recursive_dependencies = Set(String).new
        @dependencies.each do |d|
          case d
          when Job
            @recursive_dependencies.concat(d.recursive_dependencies)
          else
            @recursive_dependencies.add(d)
          end
        end
        hexdigest = Digest::MD5.hexdigest do |ctx|
          ctx.update(@name)
          flags.each { |s| ctx.update(s) }
          @recursive_dependencies.each { |s| ctx.update(s.to_s) }
        end
        jobname = @name
        jobname = jobname[0...20] if jobname.size > 20
        jobname = jobname.gsub(/[^A-Za-z0-9]/, "_")
        @file = File.join(@outdir, "#{jobname}-#{hexdigest}.crj")
      end

      def inspect
        "<Job @name=#{@name.inspect} @outdir=#{@outdir.inspect} @dependencies=#{@dependencies.inspect} @result=#{@result.inspect}>"
      end

      def modification_time
        File.info(@file).modification_time
      end

      private def save(result : Result)
        FileUtils.mkdir_p(File.dirname(@file))
        File.open(@file, "wb") do |io|
          Compress::Gzip::Writer.open(io) { |gzip| result.write(gzip) }
        end
      end

      private def last_result
        @last_result ||=
          begin
            # Reading directly from the file will fail. Seems to be a bug
            mem = IO::Memory.new
            File.open(@file, "rb") do |io|
              Compress::Gzip::Reader.open(io) { |gzip| IO.copy(gzip, mem) }
            end
            mem.rewind
            Result.read(mem, File.info(@file).modification_time)
          rescue File::NotFoundError
          rescue exc : IO::EOFError
            raise "Invalid file format in #{@file} #{exc}"
          rescue Exception
            File.delete(@file) if File.readable?(@file)
            nil
          end
      end

      def build(policy : Policy) : Result
        if @result.nil?
          begin
            result : Result = if policy.rebuild_required?(self)
              rebuild(policy)
            else
              last_result.not_nil!
            end
            save(result)
            @result = result
          rescue e : Exception
            @result = e
          end
        end
        case @result
        when Exception
          raise @result.as(Exception)
        when Result
          @result.as(Result)
        else
          raise "Should never happen"
        end
      end

      private def build_dependencies_parallel(policy)
        jobs = Channel(Tuple(Int32, Job)).new
        results = Channel(Tuple(Int32, ResultOrException)).new
        result = Array(Result | String).new(@dependencies.size,"")
        counter = 0
        policy.n_threads.times.each do
          spawn do
            while true
              begin
                i, job = jobs.receive
                begin
                  results.send({i, job.build(policy)})
                rescue exc : Exception
                  results.send({i, exc})
                end
              rescue exc: Channel::ClosedError
                break
              end
            end
          end
        end
        @dependencies.each_index do |i|
          dependency = @dependencies[i]
          case dependency
          when Job
            jobs.send({i, dependency})
            counter += 1
          else
            result[i] = dependency
          end
        end
        while counter > 0
          i, r = results.receive
          counter -= 1
          case r
          when Result
            result[i] = r
          else
            raise r
          end
        end
        jobs.close
        result
      end

      private def build_dependencies(policy)
        result : Array(Result | String) = @dependencies.map do |dependency|
          case dependency
          when Job
            dependency.build(policy)
          else
            dependency
          end
        end
        result
      end

      private def rebuild(policy)
        built_dependencies = if @dependencies.size > 1 && policy.n_threads > 1
                               build_dependencies_parallel(policy)
                             else
                               build_dependencies(policy)
                             end

        simple_dependencies = built_dependencies.map do |dependency|
          case dependency
          when Result
            dependency.result
          else
            dependency
          end
        end
        block_result = @block.call(simple_dependencies)
        result = case block_result
                 when String
                   Result.new(block_result)
                 else
                   block_result.as(Result)
                 end
        built_dependencies.each do |dependency|
          result.recursive_buildtime_dependencies.concat(dependency.recursive_buildtime_dependencies) if dependency.is_a?(Result)
        end
        result
      end

      def recursive_buildtime_dependencies
        case @result
        when Result
          @result.as(Result).recursive_buildtime_dependencies
        else
          case last_result
          when Result
            last_result.as(Result).recursive_buildtime_dependencies
          else
            raise File::NotFoundError.new("No recursive_buildtime_dependencies found", file: @file)
          end
        end
      end

      def to_s
        @name
      end

      def clear
        @result = nil
        @last_result = nil
      end
    end
  end
end
