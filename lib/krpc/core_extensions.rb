
class Module
  def class_name
    name.rpartition("::").last
  end
  
  def const_get_or_create(module_name, value = nil, &block)
    return const_get(module_name) if const_defined?(module_name, false)
    value = block.call if block_given?
    const_set(module_name, value)
    value
  end
end

module Boolean; end
class TrueClass; include Boolean; end
class FalseClass; include Boolean; end

class String
  def underscore
    self.gsub(/::/, '/').
    gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
    gsub(/([a-z\d])([A-Z])/,'\1_\2').
    tr("-", "_").
    downcase
  end
end
