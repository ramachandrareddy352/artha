// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

/**
 * @title  DiamondLoupeFacet
 * @notice Read-only facet enumeration. Every loop here is bounded by the total
 *         number of installed selectors (a small, governance-controlled number, not
 *         user-controlled input), and these functions are never called from another
 *         on-chain transaction — only by off-chain tooling and block explorers — so
 *         the O(n^2) worst case in `facets()`/`facetFunctionSelectors()` is
 *         intentional and cannot be griefed by a user.
 */
contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
    function facets() external view override returns (Facet[] memory facets_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numSelectors = ds.selectors.length;

        address[] memory facetAddrs = new address[](numSelectors);
        uint256 numFacets;
        for (uint256 i; i < numSelectors; i++) {
            address facetAddr = ds.facetAddressAndSelectorPosition[ds.selectors[i]].facetAddress;
            bool seen;
            for (uint256 j; j < numFacets; j++) {
                if (facetAddrs[j] == facetAddr) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                facetAddrs[numFacets] = facetAddr;
                numFacets++;
            }
        }

        facets_ = new Facet[](numFacets);
        for (uint256 k; k < numFacets; k++) {
            facets_[k].facetAddress = facetAddrs[k];
            facets_[k].functionSelectors = _selectorsForFacet(ds, facetAddrs[k]);
        }
    }

    function facetFunctionSelectors(address _facet)
        external
        view
        override
        returns (bytes4[] memory facetFunctionSelectors_)
    {
        return _selectorsForFacet(LibDiamond.diamondStorage(), _facet);
    }

    function facetAddresses() external view override returns (address[] memory facetAddresses_) {
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        uint256 numSelectors = ds.selectors.length;

        address[] memory temp = new address[](numSelectors);
        uint256 numFacets;
        for (uint256 i; i < numSelectors; i++) {
            address facetAddr = ds.facetAddressAndSelectorPosition[ds.selectors[i]].facetAddress;
            bool seen;
            for (uint256 j; j < numFacets; j++) {
                if (temp[j] == facetAddr) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                temp[numFacets] = facetAddr;
                numFacets++;
            }
        }

        facetAddresses_ = new address[](numFacets);
        for (uint256 k; k < numFacets; k++) {
            facetAddresses_[k] = temp[k];
        }
    }

    function facetAddress(bytes4 _functionSelector) external view override returns (address facetAddress_) {
        facetAddress_ = LibDiamond.diamondStorage().facetAddressAndSelectorPosition[_functionSelector].facetAddress;
    }

    function supportsInterface(bytes4 _interfaceId) external view override returns (bool) {
        return LibDiamond.diamondStorage().supportedInterfaces[_interfaceId];
    }

    function _selectorsForFacet(LibDiamond.DiamondStorage storage ds, address _facet)
        private
        view
        returns (bytes4[] memory result)
    {
        uint256 numSelectors = ds.selectors.length;
        uint256 count;
        for (uint256 i; i < numSelectors; i++) {
            if (ds.facetAddressAndSelectorPosition[ds.selectors[i]].facetAddress == _facet) count++;
        }

        result = new bytes4[](count);
        uint256 idx;
        for (uint256 i; i < numSelectors; i++) {
            bytes4 sel = ds.selectors[i];
            if (ds.facetAddressAndSelectorPosition[sel].facetAddress == _facet) {
                result[idx] = sel;
                idx++;
            }
        }
    }
}
