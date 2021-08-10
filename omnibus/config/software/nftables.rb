# frozen_string_literal: true

# Copyright:: FireZone
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
name "nftables"
default_version "0.9.9"

source url: "https://www.netfilter.org/pub/nftables/nftables-0.9.9.tar.bz2"

version("0.9.9") { source sha256: "76ef2dc7fd0d79031a8369487739a217ca83996b3a746cec5bda79da11e3f1b4" }

relative_path "nftables-#{version}"

dependency "gmp"
dependency "m4"
dependency "bison"
dependency "flex"
dependency "libmnl"
dependency "libnftnl"
dependency "readline"

build do
end
