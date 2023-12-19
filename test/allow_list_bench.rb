# frozen_string_literal: true

require "semian"
require "active_record"
require "semian/activerecord_trilogy_adapter"
require "benchmark/ips"

# sql_commit = "/*key:value,key:morevalue,morekey:morevalue,id:IDIDIDIDI,anotherkey:anothervalue,k:v,k:v*/ COMMIT"

# Common case
sql_not_commit = "/*key:value,key:morevalue,morekey:morevalue,id:IDIDIDIDID,anotherkey:anothervalue,k:v,k:v*/ SELECT /*+ 1111111111111111111111111*/ `line_items`.`id`, `line_items`.`shop_id`, `line_items`.`title`, `line_items`.`sku`, `line_items`.`vendor`,`line_items`.`variant_id`, `line_items`.`variant_title`, `line_items`.`order_id`, `line_items`.`currency`, `line_items`.`presentment_price`, `line_items`.`price`, `line_items`.`gift_card` FROM `line_items` WHERE `line_items`.`id` = ASKJAKJSDASDKJ"

Benchmark.ips do |x|
  x.report("end-with-case?") do
    Semian::ActiveRecordTrilogyAdapter.query_allowlisted?(sql_not_commit)
  end

  x.report("regex") { Semian::ActiveRecordTrilogyAdapter::QUERY_ALLOWLIST.match?(sql_not_commit) }
  x.compare!
end
