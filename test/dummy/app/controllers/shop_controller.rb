# A host-app page for exercising the capture widget in tests and local demos.
class ShopController < ApplicationController
  def index
    @invoices = [ { number: "INV-7", total: "12.50" }, { number: "INV-8", total: "99.99" } ]
  end
end
