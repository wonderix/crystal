require "../syntax/visitor"

module Crystal
  class ModuleSplitVisitor < Visitor
    getter object_files
    record ObjectFile, name : String, owner : Type, defs = Hash(String, Def).new

    @types_to_object_files = {} of Type => ObjectFile

    def initialize(@program : Program, @single_module : Bool)
      @main_object_file = ObjectFile.new("main", @program)
      @object_files = {"" => @main_object_file} of String => ObjectFile
      @proc_counts = Hash(String, Int32).new(0)
    end

    def visit(node : Call)
      if node.expanded
        raise "BUG: #{node} at #{node.location} should have been expanded"
      end

      target_defs = node.target_defs
      unless target_defs
        return false
        # node.raise "BUG: no target defs"
      end

      if target_defs.size > 1
        codegen_dispatch node, target_defs
        return false
      end

      owner = node.super? ? node.scope : node.target_def.owner

      prepare_call_args node

      if block = node.block
        # A block might turn into a proc literal but not be used if it participates in a dispatch
        if (fun_literal = block.fun_literal) && node.target_def.uses_block_arg?
          codegen_call_with_block_as_fun_literal(node, fun_literal, owner)
        else
          codegen_call_with_block(node)
        end
      else
        codegen_call(node.target_def, owner)
      end

      false
    end

    def visit(node : ProcPointer)
      node.call?.try do |c|
        owner = c.target_def.owner

        if obj = node.obj
          accept obj
        end

        target_def_fun(c.target_def, owner)
      end
      false
    end

    def visit(node : FunDef)
      if node.external.used?
        codegen_fun node.real_name, node.external, @program, is_exported_fun: true
      else
        codegen_fun node.real_name, node.external, @program, is_exported_fun: false
      end

      false
    end

    def prepare_call_args(node)
      obj = node.obj

      accept obj if obj

      node.args.each do |arg|
        accept arg
      end
    end

    def fun_literal_name(node : ProcLiteral)
      location = node.location.try &.expanded_location
      if location && (type = node.type?)
        proc_name = true
        filename = location.filename.as(String)
        fun_literal_name = Crystal.safe_mangling(@program, "~proc#{type}@#{Crystal.relative_filename(filename)}:#{location.line_number}")
      else
        proc_name = false
        fun_literal_name = "~fun_literal"
      end
      proc_count = @proc_counts[fun_literal_name]
      proc_count += 1
      @proc_counts[fun_literal_name] = proc_count

      if proc_count > 1
        if proc_name
          fun_literal_name = "#{fun_literal_name[0...5]}#{proc_count}#{fun_literal_name[5..-1]}"
        else
          fun_literal_name = "#{fun_literal_name}#{proc_count}"
        end
      end

      fun_literal_name
    end

    def visit(node : ProcLiteral)
      fun_literal_name = fun_literal_name(node)

      if node.force_nil?
        node.def.set_type @program.nil
      else
        # node.def.set_type node.return_type
      end

      codegen_fun(fun_literal_name, node.def, nil, object_file: @main_object_file)

      false
    end

    def visit(node : If)
      accept node.cond
      accept node.then
      accept node.else
      false
    end

    def codegen_dispatch(node, target_defs)
      # Get type_id of obj or owner
      if node_obj = node.obj
        owner = node_obj.type
        accept node_obj
      elsif node.uses_with_scope? && (with_scope = node.with_scope)
        owner = with_scope
      else
        owner = node.scope
      end

      node.args.each do |arg|
        accept arg
      end

      # Reuse this call for each dispatch branch
      call = Call.new(node_obj ? Var.new("%self") : nil, node.name, node.args.map_with_index { |arg, i| Var.new("%arg#{i}").as(ASTNode) }, node.block).at(node)
      call.scope = with_scope || node.scope
      call.with_scope = with_scope
      call.uses_with_scope = node.uses_with_scope?
      call.name_location = node.name_location

      target_defs.each do |a_def|
        # Prepare this specific call
        call.target_defs = [a_def] of Def
        call.obj.try &.set_type(a_def.owner)
        call.args.zip(a_def.args) do |call_arg, a_def_arg|
          call_arg.set_type(a_def_arg.type)
        end
        if (node_block = node.block) && node_block.break.type?
          call.set_type(@program.type_merge [a_def.type, node_block.break.type] of Type)
        else
          call.set_type(a_def.type)
        end
        accept call
      end
    end

    def codegen_call_with_block(node)
      accept node.target_def.body
    end

    def codegen_call_with_block_as_fun_literal(node, fun_literal, self_type)
      accept fun_literal
      target_def_fun(node.target_def, self_type)
    end

    def codegen_call(target_def, self_type)
      body = target_def.body

      if try_inline_call(target_def, body) || body.is_a?(Primitive)
        return
      end
      target_def_fun(target_def, self_type)
    end

    def try_inline_call(target_def, body)
      return false if target_def.is_a?(External)

      case body
      when Nop, NilLiteral, BoolLiteral, CharLiteral, StringLiteral, NumberLiteral, SymbolLiteral
        true
      when Var
        body.name == "self"
      when InstanceVar
        true
      else
        false
      end
    end

    def target_def_fun(target_def, self_type)
      mangled_name = target_def.mangled_name(@program, self_type)
      object_file = type_module(self_type)
      unless object_file.defs[mangled_name]?
        codegen_fun(mangled_name, target_def, self_type)
      end
    end

    def type_module(self_type)
      return @main_object_file if @single_module

      mod = @types_to_object_files[self_type] ||= begin
        type = self_type.remove_typedef
        case type
        when Nil, Program, LibType
          type_name = ""
        else
          type_name = type.instance_type.to_s
        end

        @object_files[type_name] ||= ObjectFile.new(type_name, self_type)
      end
    end

    def codegen_fun(mangled_name, target_def, self_type, is_exported_fun = false, object_file = type_module(self_type))
      object_file.defs[mangled_name] = target_def
      needs_body = !target_def.is_a?(External) || is_exported_fun
      if needs_body
        body = target_def.body

        unless body.is_a?(Primitive)
          accept target_def.body
        end
      end
    end

    def visit_any(node)
      true
    end

    def visit(node)
      true
    end

    def accept(node)
      node.accept self
    end

    def dump
      @object_files.each do |k, v|
        puts(k)
        v.defs.each_key do |name|
          puts("  #{name}")
        end
      end
    end
  end
end
