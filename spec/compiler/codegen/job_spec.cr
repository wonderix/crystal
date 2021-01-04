require "spec"
require "compiler/crystal/codegen/job"
require "../../support/tempfile"

include Crystal::Build

def create_file(dir, name)
  Dir.mkdir(dir) unless File.directory?(dir)
  file = File.join(dir, name)
  File.touch(file)
  file
end

describe Result do
  it "reads and writes the same format" do
    with_tempfile("tmp") do |tmp|
      file = create_file(tmp, "töst")
      io = IO::Memory.new
      result = Result.new(file, Set{file})
      result.write(io)
      io.rewind
      Result.read(io, result.modification_time).should eq result
    end
  end
end

describe Job do
  it "initializes" do
    job = Job.new("test", "/tmp") { |dependencies| "hello" }
  end

  it "builds" do
    with_tempfile("cache", "tmp") do |cache, tmp|
      job = Job.new("test", cache) { |dependencies| create_file(tmp, "hello") }
      job.build(AlwaysBuildPolicy.new).result.to_s.should eq File.join(tmp, "hello")
    end
  end

  it "doesn't rebuild" do
    with_tempfile("cache", "tmp") do |cache, tmp|
      job = Job.new("test", cache) { |dependencies| create_file(tmp, "hello") }
      job.build(ModificationTimeBuildPolicy.new)
      job = Job.new("test", cache) { |dependencies| raise "test" }
      job.build(ModificationTimeBuildPolicy.new).result.should eq File.join(tmp, "hello")
    end
  end

  it "builds dependencies recursively" do
    with_tempfile("cache", "tmp") do |cache, tmp|
      dependency = Job.new("test", cache) { |dependencies| create_file(tmp, "hello") }
      job = Job.new("test", cache, dependencies: [dependency]) { |dependencies| dependencies[0] }
      job.build(ModificationTimeBuildPolicy.new).result.should eq File.join(tmp, "hello")
    end
  end

  it "builds dependencies in parallel" do
    with_tempfile("cache", "tmp") do |cache, tmp|
      dependency1 = Job.new("test1", cache) { |dependencies| create_file(tmp, "hello1") }
      dependency2 = Job.new("test2", cache) { |dependencies| create_file(tmp, "hello2") }
      job = Job.new("test", cache, dependencies: [dependency1,dependency2]) { |dependencies| dependencies[0] }
      policy = ModificationTimeBuildPolicy.new
      policy.n_threads = 2
      job.build(policy).result.should eq File.join(tmp, "hello1")
    end
  end

  it "honors build dependencies" do
    with_tempfile("cache", "tmp") do |cache, tmp|
      buildtime_dependency = create_file(tmp, "header.h")
      job = Job.new("test", cache) do |dependencies|
        Result.new(create_file(tmp, "hello"), Set{buildtime_dependency})
      end
      job.build(ModificationTimeBuildPolicy.new).modification_time
      reference_time = Time.utc
      job.clear
      job.build(ModificationTimeBuildPolicy.new).modification_time.should be <= reference_time
      job.clear
      File.touch(buildtime_dependency)
      job.build(ModificationTimeBuildPolicy.new).modification_time.should be > reference_time
    end
  end

  it "honors recursive build dependencies" do
    with_tempfile("cache", "tmp") do |cache, tmp|
      buildtime_dependency = create_file(tmp, "header.h")
      dependency = Job.new("test", cache) { |dependencies| Result.new(create_file(tmp, "hello"), Set{buildtime_dependency}) }

      job = Job.new("test", cache, dependencies: [dependency]) do |dependencies|
        dependencies[0]
      end
      job.build(ModificationTimeBuildPolicy.new).modification_time
      reference_time = Time.utc
      job.clear
      job.build(ModificationTimeBuildPolicy.new).modification_time.should be <= reference_time
      job.clear
      File.touch(buildtime_dependency)
      job.build(ModificationTimeBuildPolicy.new).modification_time.should be > reference_time
    end
  end
end
