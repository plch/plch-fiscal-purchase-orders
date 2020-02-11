# PLCH-FISCAL

## Purchase Order Creation

### Definitions

__purchase order__: a collection of one or more __order record__ sharing the same `blanket_purchase_order_num`

__order record__: a record containing the following information (mostly defined in the sierra database: [sierra dna table view - order_record](https://techdocs.iii.com/sierradna/Home.html?viewGroupName=Order#order_record) ):

* record_id

* vendor_record_code

* order_date_gmt

* form_code

  * Code specifying the physical form of the material. e.g. b = book, p = periodical etc

* order_status_code

  * Financial encumbering/disencumbering status of record.

* blanket_purchase_order_num

* estimated_price::numeric(30,2) as estimated_price

  * Estimated price for one copy of the ordered item.

---

### Steps

The following is done in this query: [purchase_order_temp_tables.sql](purchase_order_temp_tables.sql):

1. Gather all order record data from the database (`temp_order_record`). For a final product of the "purchase order", we'll need to put all the orders on that document based on the "last updated" order record.

   In other words, changing one order record will "refresh" the entire "Purchase Order" document.

1. Create "purchase order" record metadata:
   * `temp_blanket_purchase_order_metadata` from the order records created in the first step (for each distinct "purchase order"). The purpose of this table is so that we can target sets of "purchase orders" for export:

     * `latest_order_data` : order record latest date made associated with that "purchase order"

     * `last_order_record_updated` : latest order record _updated_ date associated with that "purchase order"

1. Target the purchase orders we wish to produce, and store them in the temp table `temp_target_purchase_orders`:

   * From the `temp_blanket_purchase_order_metadata` grab all the purchase orders where `last_order_record_updated` is greater than our last export date. (Is this correct? or do we want the created date)
