# -*- encoding: utf-8 -*-
# stub: twilio 3.1.1 ruby lib

Gem::Specification.new do |s|
  s.name = "twilio".freeze
  s.version = "3.1.1".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Phil Misiowiec".freeze, "Jonathan Rudenberg".freeze, "Alex K Wolfe".freeze, "Kyle Daigle".freeze, "Jeff Wigal".freeze, "Yuri Gadow".freeze, "Vlad Moskovets".freeze]
  s.date = "2013-01-12"
  s.description = "Twilio API wrapper".freeze
  s.email = ["github@webficient.com".freeze]
  s.homepage = "".freeze
  s.rubygems_version = "3.5.6".freeze
  s.summary = "Twilio API Client".freeze

  s.installed_by_version = "3.5.6".freeze if s.respond_to? :installed_by_version

  s.specification_version = 3

  s.add_runtime_dependency(%q<builder>.freeze, [">= 2.1.2".freeze])
  s.add_runtime_dependency(%q<httparty>.freeze, [">= 0.8".freeze])
  s.add_development_dependency(%q<rake>.freeze, ["~> 0.8.7".freeze])
  s.add_development_dependency(%q<rspec>.freeze, ["~> 2.12".freeze])
  s.add_development_dependency(%q<webmock>.freeze, ["~> 1.6.2".freeze])
end
