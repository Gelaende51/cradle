# Additions
## README.md
- create README.md in the root translations in docs/i18n/README.{bpc47 code}.md
- the readme should contain:
 - all contributions
 - disclosure of AI coding including model name and service provider
  - include approximate tokens used
  - put it above the other headings but below the description
  - make it concise and into a bullet point list for agent and author
 - a reference to the license file, documentation, web presence, donation option, issue tracker
 - showcase the features and how to use them if not obvious in a concise bulltet point style
 - installation instructions
 - reference software that integrates with this project or workflow
 - reference similar projects and their differences to this project
 - make it concise. the deep dive is for the documentation
 . avoid redundant or very obvious features. ask which ones to include
 - donation links should contain adesignation for the donation which will be depending on the project:
  - carbon offset
  - server cost
  - support dependencies
  - general free software donations especially since that is the training data for the coding models
  - subscriptions
  - legal cost
  - hardware purchases
 ## License
 - if not specified ask what License to pick. put the LICENSE file into the project root

## Documentation

## Localization
- always add localization to the software for the most common languages. preferrably for the ones that this model can translate well

# Development
- create a remote repository with the specified account on the specified hoster
- when fake user data is needed to test a project ask the handler for a theme
- use codegraph

# Design
- For every feature consider the impact on
 - functionality
 - ui
 - resources
 - security
 - dependencies
 - compatibility
 - redundancy

# Implementation
- use existing libraries if applicable or adapable
- if a library is has enough useful parts to be worth it but is incompatible for the use case fork and adapt/extend it in a way it is also useful for the open source community
- workarounds, bugs, missing features and noteworthy discoveries about used libraries should be retained in the takeaways.md file. the reason is for reference and to potentially create bug reports, feature requests or pull requests

# Takeaways
- create a list of distinct challanges, oddities or insights that appear during the implementation of the project in a ./dev/takeaways.md file