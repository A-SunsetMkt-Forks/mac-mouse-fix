
#
# Imports
#

import argparse
import os
import glob
from collections import defaultdict
import json

import mflocales
import mfutils


#
# Constants
#

#
# Main
#
def main():
    
    # Parse args
    parser = argparse.ArgumentParser()
    parser.add_argument('--target_repo', required=True, help='This arg should be automatically provided by run.py and point to the mmf-website-repo')
    parser.add_argument('--output_path', required=True, help='This is the relative path from the mmf-website-repo to output file')
    args = parser.parse_args()
    target_repo = args.target_repo
    output_subpath = args.output_path
    
    # Compile args
    output_path = os.path.join(target_repo, output_subpath)
    
    # Log
    print(f'compile_website_strings: Invoked with args: {args}')
    
    # Validate
    output_path_ext = os.path.splitext(output_path)[1]
    assert output_path_ext == '.js', f'Path extension of output path should be ".js". Is "{output_path_ext}".'
    
    # Find mmf-project locales
    source_locale, translation_locales = mflocales.find_mmf_project_locales()
    locales = [source_locale] + translation_locales
    
    # Log
    print(f'compile_website_strings: Found source_locale: {source_locale}, translation_locales: {translation_locales}')
    
    # Sort 
    #   We sort the locales - this way that vue will display the languages in a nice order
    locales = mflocales.sorted_locales(locales, source_locale)
    
    # Find .xcstrings files in mmf-website-repo
    #   Note: I don't think we're treating the quotes.xcstrings in a special way, so not sure this code is necessary, we could just iterate through the .xcstrings files
    xcstrings_paths = glob.glob(os.path.join(target_repo, '**/*.xcstrings'))
    assert(len(xcstrings_paths) == 2)
    main_xcstrings_path = None
    quotes_xcstrings_path = None
    if os.path.basename(xcstrings_paths[0]) == 'Quotes.xcstrings':
        quotes_xcstrings_path, main_xcstrings_path = xcstrings_paths
    elif os.path.basename(xcstrings_paths[1]) == 'Quotes.xcstrings':
        main_xcstrings_path, quotes_xcstrings_path = xcstrings_paths
    else:
        assert False
    
    # Load xcstrings files
    main_xcstrings = json.loads(mfutils.read_file(main_xcstrings_path))
    quotes_xcstrings = json.loads(mfutils.read_file(quotes_xcstrings_path))
    
    # Get progress
    progress = mflocales.get_localization_progress([main_xcstrings, quotes_xcstrings], translation_locales)
    
    # Log
    print(f'compile_website_strings: Loaded .xcstrings file at {main_xcstrings_path}, loaded Quotes.xcstrings from: {quotes_xcstrings_path}')
    
    # Compile
    
    # Compile xcstrings 
    vuestrings = {}
    vuelangs = []
    
    for locale in locales:
        
        # Get progress string 
        #   For this locale
        progress_display = str(int(100*progress[locale]["percentage"])) + '%' if locale != source_locale else ''
            
        # Compile list-of-languages dict
        #   (These are parsed as nuxt i18n `LocaleObject`s, but we add the 'progressDisplay' field for our custom logic.)
        vuelangs.append({
            'code': locale,
            'name': mflocales.language_tag_to_language_name(locale, locale, include_flag=True),
            'progressDisplay': progress_display
        })
        
        # Compile new vuestrings dict
        #   that @nuxtjs/i18n can understand
        #   Notes:
        #       - Note that we enabled fallbacks. This means the resulting Localizable.js file will aleady contain best-effort fallbacks for each string for each language. 
        #           So we don't need extra fallback logic inside the mmf-website code.
        vuestrings[locale] = {}
        for xcstrings in [main_xcstrings, quotes_xcstrings]:
            for key in xcstrings['strings']:
                value, locale_of_value = mflocales.get_translation(xcstrings, key, locale, fall_back_to_next_best_language=True)
                assert value != None # Since we enabled fallbacks, there should be a value for every string
                vuestrings[locale][key] = value
            

    
    # Render the compiled data to a .js file
    #   We could also render it to json, but json doesn't allow comments, which we want to add.
    vuestrings_json = json.dumps(vuestrings, indent=4)
    vuelangs_json = json.dumps(vuelangs, indent=4)
    js_string = f"""\
//
// AUTOGENERATED - DO NOT EDIT
// This file is automatically generated and should not be edited manually. 
// It was converted from an .xcstrings file, by the CompileWebsiteStrings script (which is from the mac-mouse-fix repo).
//
export default {{
    "sourceLocale": "{source_locale}",
    "locales": {vuelangs_json},
    "strings":
{mfutils.add_indent(vuestrings_json, 4)}
    
}};
"""
    
    # Log
    print(f'compile_website_strings: Compiled strings dict for nuxtjs i18n')

    # Write to output_path
    with open(output_path, 'w') as file:
        file.write(js_string)
    
    # Log
    print(f'compile_website_strings: Wrote strings dict to {output_path}')
    
#
# Call main
#
if __name__ == '__main__':
    main()