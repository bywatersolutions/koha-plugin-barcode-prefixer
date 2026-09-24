# Barcode Prefixer for Koha

This plugin allows Koha to prefix item and patron barcodes on a per-branch basis. It is meant for consortia where member libraries scan short local barcodes but Koha stores full length barcodes with a library specific prefix. It can also generate the next prefixed patron cardnumber or item barcode when one is left blank.

## Downloading

From the [release page](https://github.com/bywatersolutions/koha-plugin-barcode-prefixer/releases) you can download the relevant *.kpz file

## Requirements

Koha 24.05 or later. Generating patron cardnumbers needs Koha's `autoMemberNum` system preference enabled.

## Configuration

The configuration is a YAML document entered on the plugin's configuration page. Changes take effect immediately, no restart is needed.

```yaml
auto_barcode: incremental
always_transform: 0
item_barcode_length: 14
patron_barcode_length: 14
prefill_patron_cardnumber: 0
patron_prefix_library: login
only_prefix_if: '^[12]'
never_prefix_if_item: '^2'
libraries:
  MPL:
    item_barcode_length: 20
    patron_barcode_length: 22
    item_prefix: 1001
    patron_prefix: 1002
  CPL:
    item_prefix: 2001
    patron_prefix: 2002
    prefix_without_padding: 1
  SPL:
    item_prefix: 3001
    patron_prefix: 3002
    prefill_patron_cardnumber: 1
```

### How barcodes are prefixed

Whenever Koha handles an item barcode ( circulation, the item editor and every other item save, batch tools, inventory, SIP, self checkout, the REST API ) or a patron cardnumber ( checkouts, the patron entry form, SIP, self checkout, and every patron save ) the plugin looks up the settings for the logged in library and, if the barcode is shorter than the configured length, prepends the library's prefix and enough zeros to reach that length. A barcode that is already the full length or longer is left alone. Only all digit barcodes are prefixed unless `always_transform` is set.

For example, with `item_barcode_length: 14` and `item_prefix: 1001`, a scanned `12` becomes `10010000000012`.

Regular expressions let you leave some barcodes alone. A barcode is only prefixed when it matches every `only_prefix_if*` expression and none of the `never_prefix_if*` expressions that apply to it, at both the global and the library level.

### Global options

| Option | Default | Description |
|---|---|---|
| `item_barcode_length` | none | Length item barcodes are padded to. Can be overridden per library. Without a length ( global or per library ) item barcodes are not prefixed unless the library sets `prefix_without_padding`. |
| `patron_barcode_length` | none | Same for patron cardnumbers. |
| `always_transform` | `0` | Set to `1` to also prefix barcodes that contain something other than digits. |
| `auto_barcode` | none | Set to `incremental` to generate the next item barcode when an item is added without one. See below. |
| `prefill_patron_cardnumber` | `0` | Set to `1` to show the next patron cardnumber on the patron entry form before saving. See below. |
| `patron_prefix_library` | `login` | Set to `form` to use the library chosen on the patron entry form instead of the logged in library. See below. |
| `only_prefix_if` | none | Regular expression a barcode must match to be prefixed, e.g. `^1` only prefixes barcodes starting with 1. |
| `only_prefix_if_item` | none | Same, item barcodes only. |
| `only_prefix_if_patron` | none | Same, patron cardnumbers only. |
| `never_prefix_if` | none | Regular expression that stops a barcode from being prefixed, e.g. `^2` leaves barcodes starting with 2 alone. |
| `never_prefix_if_item` | none | Same, item barcodes only. |
| `never_prefix_if_patron` | none | Same, patron cardnumbers only. |

### Library options

Each key under `libraries` is a Koha branchcode. A library needs an `item_prefix` and/or a `patron_prefix` for anything to happen to its barcodes.

| Option | Description |
|---|---|
| `item_prefix` | Prefix for this library's item barcodes. |
| `patron_prefix` | Prefix for this library's patron cardnumbers. |
| `item_barcode_length` | Overrides the global `item_barcode_length` for this library. |
| `patron_barcode_length` | Overrides the global `patron_barcode_length` for this library. |
| `prefix_without_padding` | Set to `1` to always prepend the prefix without any zero padding, whatever the length of the scanned barcode. No `*_barcode_length` is needed. |
| `prefill_patron_cardnumber` | Set to `1` to enable the prefill for staff logged in at this library only. |
| `only_prefix_if`, `only_prefix_if_item`, `only_prefix_if_patron` | Library level versions of the global expressions. Both levels apply. |
| `never_prefix_if`, `never_prefix_if_item`, `never_prefix_if_patron` | Library level versions of the global expressions. Both levels apply. |

### Auto-generated patron cardnumbers

When `autoMemberNum` is enabled and a patron is saved without a cardnumber, the plugin generates one instead of Koha's plain sequential number: the library's `patron_prefix`, zero padding, and the number after the highest cardnumber already in use with that prefix and length. This applies everywhere Koha generates cardnumbers ( the patron entry form, OPAC self registration, patron imports, the REST API ). A library without a `patron_prefix` or without a `patron_barcode_length` falls back to Koha's own numbering.

### Prefilling the cardnumber on the patron entry form

Koha only generates the cardnumber when the patron is saved, so the Card number field is blank until then. Some libraries want to see the number first, for example to set an initial password from its last digits. With `prefill_patron_cardnumber: 1` ( globally, or under a library to enable it for staff logged in there ) the plugin fills the Card number field on the patron entry form and the quick add form with the number the patron will get. A number typed in by hand is never replaced, and clearing the field before saving still generates a number.

Two staff members opening the form at the same time see the same number. The second one to save gets Koha's "Card number already in use" message. Clearing the field and saving again assigns the next free number.

### Following the library chosen on the patron form

By default the plugin uses the library the staff member is logged in at, even when a different library is chosen in the Library pulldown on the patron entry form. Consortia where staff create patrons for other libraries can set `patron_prefix_library: form`. The plugin then uses the library chosen on the form, both when generating a cardnumber for a blank field and when prefixing a short cardnumber typed into it. With the prefill enabled the number shown updates when the pulldown changes. That update uses the plugin's REST API route `/api/v1/contrib/barcodeprefixer/next_patron_cardnumber`, which needs the `edit_borrowers` permission that staff who add patrons already have.

Outside of the patron entry form ( self registration, imports, SIP ) the logged in library is used as before.

### Auto-generated item barcodes

With `auto_barcode: incremental`, an item saved without a barcode ( the item editor, imports, the REST API ) gets the library's `item_prefix`, zero padding, and the number after the highest item barcode already in use with that prefix and `item_barcode_length`. Both settings are required for the library. Any other value, or leaving `auto_barcode` out, disables this.
